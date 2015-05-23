/*  portVideo, a cross platform camera framework
 Copyright (C) 2005-2015 Martin Kaltenbrunner <martin@tuio.org>
 
 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.
 
 This library is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public
 License along with this library; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "AVfoundationCamera.h"

#ifdef OSC_HOST_BIG_ENDIAN
#define FourCC2Str(fourcc) (const char[]){*((char*)&fourcc), *(((char*)&fourcc)+1), *(((char*)&fourcc)+2), *(((char*)&fourcc)+3),0}
#else
#define FourCC2Str(fourcc) (const char[]){*(((char*)&fourcc)+3), *(((char*)&fourcc)+2), *(((char*)&fourcc)+1), *(((char*)&fourcc)+0),0}
#endif

@implementation FrameGrabber
- (id) initWithCameraSize:(int)cw :(int)ch :(int) bytes
{
    self = [super init];
    cam_width = cw;
    cam_height = ch;
    new_frame = false;
    crop = false;
    
    if(bytes==3) color = true;
    else color = false;
    
    buffer = new unsigned char[cam_width*cam_height*bytes];
    return self;
}

- (id) initWithCropSize:(int)cw :(int)ch :(int)bytes :(int)fw :(int)fh :(int)xo :(int)yo
{
    self = [super init];
    cam_width = cw;
    cam_height = ch;
    frm_width = fw;
    frm_height = fh;
    xoff = xo;
    yoff = yo;
    new_frame = false;
    crop = true;
    
    if(bytes==3) color = true;
    else color = false;

    buffer = new unsigned char[frm_width*frm_height*bytes];
    return self;
}


- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    
    new_frame = false;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (CVPixelBufferLockBaseAddress(imageBuffer, 0) == kCVReturnSuccess) {
        
        unsigned char *src = (unsigned char*)CVPixelBufferGetBaseAddress(imageBuffer);
        unsigned char *dest = buffer;
        
        if (color) {

            if (crop) {
                unsigned char *src_buf = src + 3*(yoff*cam_width + xoff);
                
                for (int i=0;i<frm_height;i++) {
                    memcpy(dest, src_buf, 3*frm_width);
                    
                    src_buf += 3*cam_width;
                    dest += 3*frm_width;
                }
                
            } else {
                
                memcpy(dest,src,cam_width*cam_height*3);
            }
            
        } else {

            if (crop) {
                
                src += 2*(yoff*cam_width);
                int xend = (cam_width-(frm_width+xoff));
                
                for (int i=0;i<frm_height;i++) {
                    
                    src +=  2*xoff;
                    for (int j=frm_width/2;j>0;j--) {
                        *dest++ = *src++;
                        src++;
                        *dest++ = *src++;
                        src++;
                    }
                    src +=  2*xend;
                    
                }
                
            } else {
                
                int size = cam_width*cam_height/2;
                for (int i=size;i>0;i--) {
                    *dest++ = *src++;
                    src++;
                    *dest++ = *src++;
                    src++;
                }
            }
        }
        
        new_frame = true;
    }
}

- (unsigned char*) getFrame
{
    if (new_frame){
        new_frame = false;
        return buffer;
    } else return NULL;
}


- (void)dealloc
{
    if(buffer) delete buffer;
    [super dealloc];
}
@end

AVfoundationCamera::AVfoundationCamera(const char* cfg):CameraEngine(cfg)
{
	cameraID = -1;
	
    disconnected = false;
	running=false;
	lost_frames=0;
	
    timeout = 1000;
}

AVfoundationCamera::~AVfoundationCamera()
{
    updateSettings();
    saveSettings();
    
    if (uvcController) [uvcController release];
    if (selectedVideoDevice) [selectedVideoDevice release];
    if (videoOutput) [videoOutput release];
    if (videoDevices) [videoDevices release];
    if (videoDeviceFormats) [videoDeviceFormats release];
    if (grabber) [grabber release];
}

void AVfoundationCamera::listDevices() {
    
    AVCaptureSession *captureSession = [[AVCaptureSession alloc] init];
    if (captureSession==NULL) return;
    
    NSArray *dev_list0 = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    NSArray *dev_list1 = [AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed];
    
    int capacity = [dev_list0 count] + [dev_list1 count];
    if (capacity==0)  {
        std::cout << "no AVFoundation cameras found" << std::endl;
        return;
    } else if (capacity==1) std::cout << "1 AVFoundation camera found:" << std::endl;
    else std::cout << capacity << " AVFoundation cameras found:" << std::endl;
    
    NSMutableArray *captureDevices = [NSMutableArray arrayWithCapacity:capacity];
    
    unsigned int camID = 0;
    for (AVCaptureDevice* device in dev_list0) {
        //printf("camera #%d: %s\n",camID,[[dev localizedName] cStringUsingEncoding:NSUTF8StringEncoding]);
        [captureDevices addObject:device];
        camID++;
    }
    
    for (AVCaptureDevice* device in dev_list1) {
        //printf("camera #%d: %s\n",camID,[[dev localizedName] cStringUsingEncoding:NSUTF8StringEncoding]);
        [captureDevices addObject:device];
        camID++;
    }
    
    camID = 0;
    for (AVCaptureDevice* device in captureDevices) {
        if ([device localizedName]!=NULL)
            printf("\t%d: %s\n",camID,[[device localizedName] cStringUsingEncoding:NSUTF8StringEncoding]);
        else printf("\t%d: unknown\n",camID);
        
        NSArray *captureDeviceFormats = [device formats];
        
        int32_t last_codec=0;
        for (AVCaptureDeviceFormat *format in captureDeviceFormats) {
            
            int32_t codec = CMVideoFormatDescriptionGetCodecType((CMVideoFormatDescriptionRef)[format formatDescription]);
            if (codec!=last_codec) {
                if ((codec=='yuvs') || (codec=='2vuy')) printf("\t\tformat: YUYV (%s)\n",FourCC2Str(codec));
                else if ((codec=='420v') || (codec=='420f')) printf("\t\tformat: YUV420 (%s)\n",FourCC2Str(codec));
                else if ((codec=='jpeg') || (codec=='dmb1')) printf("\t\tformat: JPEG (%s)\n",FourCC2Str(codec));
                else if (codec=='avc1') printf("\t\tformat: H.264 (%s)\n",FourCC2Str(codec));
                else if (codec=='h263') printf("\t\tformat: H.263 (%s)\n",FourCC2Str(codec));
                else if ((codec=='mp4v') || (codec=='mp2v') || (codec=='mp1v')) printf("\t\tformat: MPEG (%s)\n",FourCC2Str(codec));
                else if ((codec=='dvc ') || (codec=='dvcp')) printf("\t\tformat: DVC (%s)\n",FourCC2Str(codec));
                else if (codec==40)printf("\t\tformat: MONO8\n"); // probably incorrect workaround
                else printf("\t\tformat: other (%s)\n",FourCC2Str(codec));
            } last_codec=codec;

            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)[format formatDescription]);
            printf("\t\t\t%dx%d ",dim.width,dim.height);
            
            for (AVFrameRateRange *frameRateRange in [format videoSupportedFrameRateRanges]) {
                float fps = round([frameRateRange maxFrameRate]*100)/100.0f;
                if(int(fps)==fps) printf("%d|",int(fps));
                else printf("%'.1f|",fps);
            } printf("\b fps\n");
        }
        camID++;
    }
    
    [captureSession release];
}

bool AVfoundationCamera::findCamera() {
    
    session = [[AVCaptureSession alloc] init];
    if (session==NULL) return false;
    
    NSArray *dev_list0 = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    NSArray *dev_list1 = [AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed];
    
    int capacity = [dev_list0 count] + [dev_list1 count];
    if (capacity==0)  {
        std::cout << "no AVFoundation cameras found" << std::endl;
        cameraID = -1;
        [session release];
        return false;
    }  else if (capacity==1) std::cout << "1 AVFoundation camera found" << std::endl;
    else std::cout << capacity << " AVFoundation cameras found" << std::endl;
    
    videoDevices = [NSMutableArray arrayWithCapacity:capacity];
    for (AVCaptureDevice* dev in dev_list0) [videoDevices addObject:dev];
    for (AVCaptureDevice* dev in dev_list1) [videoDevices addObject:dev];
    
    readSettings();
    cameraID = config.device;
    if (cameraID<0) cameraID = 0;
    else if (cameraID>=[videoDevices count]) cameraID = [videoDevices count]-1;

    selectedVideoDevice = [videoDevices objectAtIndex:cameraID];
    if (selectedVideoDevice==NULL) {
        cameraID = -1;
        [session release];
        return false;
    }
    
    if ([selectedVideoDevice localizedName]!=NULL)
        sprintf(cameraName,"%s",[[selectedVideoDevice localizedName] cStringUsingEncoding:NSUTF8StringEncoding]);
    else sprintf(cameraName,"unknown");

    return true;
}

bool AVfoundationCamera::initCamera() {

    NSError *error = nil;
    videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:selectedVideoDevice error:&error];
    if (videoDeviceInput == nil) {
        return false;
    }
   
    int max_width = 0;
    int max_height = 0;
    
    int min_width = INT_MAX;
    int min_height = INT_MAX;

    videoDeviceFormats = [selectedVideoDevice formats];
    for (AVCaptureDeviceFormat* format in videoDeviceFormats) {
        
         CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)[format formatDescription]);
        //localizedName = [NSString stringWithFormat:@"%@, %d x %d", formatName, dimensions.width, dimensions.height];
        
        if ((dim.width>=max_width) && (dim.height>=max_height)) {
            max_width = dim.width;
            max_height = dim.height;
        }
        
        if ((dim.width<=min_width) && (dim.height<=min_height)) {
            min_width = dim.width;
            min_height = dim.height;
        }
    }
    
    if (config.cam_width==SETTING_MAX) config.cam_width = max_width;
    if (config.cam_height==SETTING_MAX) config.cam_height = max_height;
 
    if (config.cam_width>max_width) config.cam_width = max_width;
    if (config.cam_height>max_height) config.cam_height = max_height;

    if (config.cam_width<min_width) config.cam_width = min_width;
    if (config.cam_height<min_height) config.cam_height = min_height;
    
    AVCaptureDeviceFormat *lastFormat;
    for (AVCaptureDeviceFormat *format in videoDeviceFormats) {
        
        lastFormat = format;
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)[format formatDescription]);
        
        if ((dim.width!=config.cam_width) || (dim.height!=config.cam_height)) continue; // wrong size
        
        bool compressed=false;
        int32_t codec = CMVideoFormatDescriptionGetCodecType((CMVideoFormatDescriptionRef)[format formatDescription]);
        if ((codec=='dmb1') || (codec=='avc1')) compressed=true;
        
        if (compressed!=config.compress) continue; // wrong compression
        
        if ((config.cam_fps==SETTING_MAX) || (config.cam_fps==SETTING_MIN)) {
            float max_fps = 0;
            float min_fps = 0;
            for (AVFrameRateRange *frameRateRange in [format videoSupportedFrameRateRanges]) {
                float frames = round([frameRateRange maxFrameRate]*100)/100.0f;
                if (frames>max_fps) max_fps = frames;
                if (frames<min_fps) min_fps = frames;

            }
            if (config.cam_fps==SETTING_MAX) config.cam_fps = max_fps;
            if (config.cam_fps==SETTING_MIN) config.cam_fps = min_fps;
        }
        
        bool found = false;
        AVFrameRateRange *lastRange=NULL;
        for (AVFrameRateRange *frameRateRange in [format videoSupportedFrameRateRanges]) {
            float framerate = round([frameRateRange maxFrameRate]*100)/100.0f;
            if (framerate==config.cam_fps) { // found exact framerate
                selectedFrameRateRange = frameRateRange;
                fps = config.cam_fps;
                found = true;
                //printf("\t\tselected: %dx%d, %dfps\n",dim.width,dim.height,frames);
                break;
            } else { // determine closest framerate
                if (lastRange==NULL) continue;
                float lastrate = round([lastRange maxFrameRate]*100)/100.0f;
                
                if (((config.cam_fps<lastrate) && (config.cam_fps>framerate)) || ((config.cam_fps>lastrate) && (config.cam_fps<framerate))) {
                    float diff_last = fabs(config.cam_fps-lastrate);
                    float diff_current = fabs(config.cam_fps-framerate);
                    
                    if(diff_last<diff_current) {
                        selectedFrameRateRange = lastRange;
                        fps = lastrate;
                    } else {
                        selectedFrameRateRange = frameRateRange;
                        fps = framerate;
                    }
                }
                found = true;
                break;
            }
            lastRange = frameRateRange;
        }
        
        if (found) break;
    }
 
    [selectedVideoDevice lockForConfiguration:&error];
    [selectedVideoDevice setActiveFormat:lastFormat];
    if ([[[selectedVideoDevice activeFormat] videoSupportedFrameRateRanges] containsObject:selectedFrameRateRange]) {
        //[selectedVideoDevice setActiveVideoMaxFrameDuration:[selectedFrameRateRange maxFrameDuration]];
        [selectedVideoDevice setActiveVideoMinFrameDuration:[selectedFrameRateRange minFrameDuration]];
    }
    [selectedVideoDevice unlockForConfiguration];
 
    selectedVideoDeviceFormat = [selectedVideoDevice activeFormat];

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)[selectedVideoDeviceFormat formatDescription]);
    
    cam_width =  dimensions.width;
    cam_height = dimensions.height;
    
    for (AVFrameRateRange *frameRateRange in [selectedVideoDeviceFormat videoSupportedFrameRateRanges])
    {
        selectedFrameRateRange = frameRateRange;
        fps =[selectedFrameRateRange maxFrameRate];

        if (CMTIME_COMPARE_INLINE([frameRateRange minFrameDuration], ==, [selectedVideoDevice activeVideoMinFrameDuration])) break;
    }
    
    videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    unsigned int pixelformat = kCVPixelFormatType_422YpCbCr8_yuvs;
    if (colour) pixelformat = kCVPixelFormatType_24RGB;
    
    NSDictionary *pixelBufferOptions = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithDouble:cam_width], (id)kCVPixelBufferWidthKey,
                                        [NSNumber numberWithDouble:cam_height], (id)kCVPixelBufferHeightKey,
                                        //[NSNumber numberWithUnsignedInt:kCVPixelFormatType_422YpCbCr8_yuvs ], (id)kCVPixelBufferPixelFormatTypeKey,
                                        [NSNumber numberWithUnsignedInt: pixelformat ], (id)kCVPixelBufferPixelFormatTypeKey,
                                        nil];
    
    
    [videoOutput setVideoSettings:pixelBufferOptions];
    
    videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [session addInput:videoDeviceInput];
    [session addOutput:videoOutput];
    
    // configure output.
    setupFrame();
    dispatch_queue_t queue = dispatch_queue_create("queue", NULL);
    if (config.frame) {
        grabber = [[FrameGrabber alloc] initWithCropSize:cam_width :cam_height :bytes :frame_width :frame_height :config.frame_xoff :config.frame_yoff];
    } else {
        grabber = [[FrameGrabber alloc] initWithCameraSize:cam_width :cam_height: bytes];
    }
    [videoOutput setSampleBufferDelegate:grabber queue:queue];
    dispatch_release(queue);

    NSString *uniqueID = [selectedVideoDevice uniqueID];
    if (uniqueID!=NULL) {
        uvcController = [[VVUVCController alloc] initWithDeviceIDString:[selectedVideoDevice uniqueID]];
        if (uvcController) [uvcController resetParamsToDefaults];
    } // else std::cout << "VVUVCController NULL" << std::endl;
    
    applyCameraSettings();
    return true;
}

unsigned char* AVfoundationCamera::getFrame()
{	
    unsigned char *cambuffer = [grabber getFrame];
	if (cambuffer!=NULL) {
		timeout=100;
		lost_frames=0;
        return cambuffer;
	} else {
		usleep(10000);
		lost_frames++;
        if (lost_frames>timeout) {
            disconnected=true;
            running=false;
        }
		return NULL;		
	}
    
    return NULL;
}

bool AVfoundationCamera::startCamera()
{
    [session startRunning];
 	running = true;
	return true;
}

bool AVfoundationCamera::stopCamera()
{

    [session stopRunning];
	running=false;
	return true;
}

bool AVfoundationCamera::stillRunning() {
	return running;
}

bool AVfoundationCamera::resetCamera()
{
  return (stopCamera() && startCamera());
}

bool AVfoundationCamera::closeCamera()
{
    if (!disconnected) {
        updateSettings();
        saveSettings();
    }
    [session release];
	return true;
}

bool AVfoundationCamera::showSettingsDialog(bool lock) {
    
    if (uvcController) {
        [uvcController closeSettingsWindow];
        [uvcController openSettingsWindow];
    }
    
    return lock;
}

bool AVfoundationCamera::hasCameraSettingAuto(int mode) {
    
    if (uvcController==NULL) return false;
    
    switch (mode) {
        case EXPOSURE:
            return [uvcController autoExposureModeSupported];
        case WHITE:
            return [uvcController autoWhiteBalanceSupported];
        case FOCUS:
            return [uvcController autoFocusSupported];
        case COLOR_HUE:
            return [uvcController autoHueSupported];
    }
    
    return false;
}

bool AVfoundationCamera::getCameraSettingAuto(int mode) {
    
    if (uvcController==NULL) return false;
    if (!hasCameraSettingAuto(mode)) return false;

    switch (mode) {
        case EXPOSURE:
            if ([uvcController autoExposureMode]>UVC_AEMode_Manual) return true;
            else return false;
        case WHITE:
            return [uvcController autoWhiteBalance];
        case FOCUS:
            return [uvcController autoFocus];
        case COLOR_HUE:
            return [uvcController autoHue];
    }
    
    return false;
}

bool AVfoundationCamera::setCameraSettingAuto(int mode, bool flag) {
    
    if (uvcController==NULL) return false;
    if (!hasCameraSettingAuto(mode)) return false;
    
    switch (mode) {
        case EXPOSURE:
            if (flag==true) [uvcController setAutoExposureMode:UVC_AEMode_Auto];
            else [uvcController setAutoExposureMode:UVC_AEMode_Manual];
            return true;
        case WHITE:
            [uvcController setAutoWhiteBalance:flag];
            return true;
        case FOCUS:
            [uvcController setAutoFocus:flag];
            return true;
        case COLOR_HUE:
            [uvcController setAutoHue:flag];
            return true;
    }
    
    return false;
}

bool AVfoundationCamera::hasCameraSetting(int mode) {

    if (uvcController==NULL) return false;

    switch (mode) {
        case BRIGHTNESS:
            return [uvcController brightSupported];
        case CONTRAST:
            return [uvcController contrastSupported];
        case SHARPNESS:
            return [uvcController sharpnessSupported];
        case GAIN:
            return [uvcController gainSupported];
        case AUTO_GAIN:
            return hasCameraSettingAuto(GAIN);
        case EXPOSURE:
            return [uvcController exposureTimeSupported];
        case AUTO_EXPOSURE:
            return hasCameraSettingAuto(EXPOSURE);
        case FOCUS:
            return [uvcController focusSupported];
        case AUTO_FOCUS:
            return hasCameraSettingAuto(FOCUS);
        case WHITE:
            return [uvcController whiteBalanceSupported];
        case AUTO_WHITE:
            return hasCameraSettingAuto(WHITE);
        case BACKLIGHT:
            return [uvcController backlightSupported];
        case COLOR_HUE:
            return [uvcController hueSupported];
        case AUTO_HUE:
            return hasCameraSettingAuto(COLOR_HUE);
    }
    
    return false;
}

bool AVfoundationCamera::setCameraSetting(int mode, int setting) {
    
    if (uvcController==NULL) return false;
    if (!hasCameraSetting(mode)) return false;
    
    switch (mode) {
        case BRIGHTNESS:
            [uvcController setBright:setting]; return true;
        case CONTRAST:
            [uvcController setContrast:setting]; return true;
        case SHARPNESS:
            [uvcController setSharpness:setting]; return true;
        case GAIN:
            [uvcController setGain:setting]; return true;
        case EXPOSURE:
            [uvcController setExposureTime:setting]; return true;
        case FOCUS:
            [uvcController setFocus:setting]; return true;
        case WHITE:
            [uvcController setWhiteBalance:setting]; return true;
        case BACKLIGHT:
            [uvcController setBacklight:setting]; return true;
        case COLOR_HUE:
            [uvcController setHue:setting]; return true;
    }
    
    return false;
}



int AVfoundationCamera::getCameraSetting(int mode) {
    
    if (uvcController==NULL) return 0;
    if (!hasCameraSetting(mode)) return 0;
    if (getCameraSettingAuto(mode)) return 0;

    switch (mode) {
        case BRIGHTNESS:
            return [uvcController bright];
        case CONTRAST:
            return [uvcController contrast];
        case SHARPNESS:
            return [uvcController sharpness];
        case GAIN:
            return [uvcController gain];
        case EXPOSURE:
            return [uvcController exposureTime];
        case FOCUS:
            return [uvcController focus];
        case WHITE:
            return [uvcController whiteBalance];
        case BACKLIGHT:
            return [uvcController backlight];
        case COLOR_HUE:
            return [uvcController hue];
    }

    return 0;
}

int AVfoundationCamera::getMaxCameraSetting(int mode) {

    if (uvcController==NULL) return 0;
    if (!hasCameraSetting(mode)) return 0;
    if (getCameraSettingAuto(mode)) return 0;

    switch (mode) {
        case BRIGHTNESS:    return [uvcController maxBright];
        case CONTRAST:      return [uvcController maxContrast];
        case SHARPNESS:     return [uvcController maxSharpness];
        case GAIN:          return [uvcController maxGain];
        case EXPOSURE:      return [uvcController maxExposureTime];
        case FOCUS:         return [uvcController maxFocus];
        case WHITE:         return [uvcController maxWhiteBalance];
        case BACKLIGHT:     return [uvcController maxBacklight];
        case COLOR_HUE:     return [uvcController maxHue];
    }
    
    return 0;
}

int AVfoundationCamera::getMinCameraSetting(int mode) {
 
    if (uvcController==NULL) return 0;
    if (!hasCameraSetting(mode)) return 0;
    if (getCameraSettingAuto(mode)) return 0;

    switch (mode) {
        case BRIGHTNESS:    return [uvcController minBright];
        case CONTRAST:      return [uvcController minContrast];
        case GAIN:          return [uvcController minGain];
        case EXPOSURE:      return [uvcController minExposureTime];
        case SHARPNESS:     return [uvcController minSharpness];
        case FOCUS:         return [uvcController minFocus];
        case WHITE:         return [uvcController minWhiteBalance];
        case BACKLIGHT:     return [uvcController minBacklight];
        case COLOR_HUE:     return [uvcController minHue];
    }
    
    return 0;
}

bool AVfoundationCamera::setDefaultCameraSetting(int mode) {

    if (uvcController==NULL) return false;
    if (!hasCameraSetting(mode)) return false;

    switch (mode) {
        case BRIGHTNESS:
            [uvcController resetBright];
            default_brightness = [uvcController bright];
            break;
        case CONTRAST:
            [uvcController resetContrast];
            default_contrast = [uvcController contrast];
            break;
        case SHARPNESS:
            [uvcController resetSharpness];
            default_sharpness = [uvcController sharpness];
            break;
        case GAIN:
            [uvcController resetGain];
            default_gain = [uvcController gain];
            break;
        case EXPOSURE:
            [uvcController resetExposureTime];
            default_exposure = [uvcController exposureTime];
            break;
        case FOCUS:
            [uvcController resetFocus];
            default_focus = [uvcController focus];
            break;
        case WHITE:
            [uvcController resetWhiteBalance];
            default_white = [uvcController whiteBalance];
            break;
        case BACKLIGHT:
            [uvcController resetBacklight];
            default_backlight = [uvcController backlight];
            break;
        case COLOR_HUE:
            [uvcController resetHue];
            default_hue = [uvcController hue];
            break;
            
    }

    return false;
}

int AVfoundationCamera::getDefaultCameraSetting(int mode) {
    
    if (uvcController==NULL) return 0;
    if (!hasCameraSetting(mode)) return 0;
    
    switch (mode) {
        case BRIGHTNESS: return default_brightness;
        case CONTRAST: return default_contrast;
        case GAIN: return default_gain;
        case EXPOSURE: return default_exposure;
        case SHARPNESS: return default_sharpness;
        case FOCUS: return default_focus;
        case WHITE: return default_white;
        case BACKLIGHT: return default_backlight;
        case COLOR_HUE: return default_hue;
    }
    
    return 0;
}

int AVfoundationCamera::getCameraSettingStep(int mode) {
    if (!hasCameraSetting(mode)) return 0;
    return 1;
}
