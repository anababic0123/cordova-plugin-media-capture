/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVCapture.h"
#import "CDVFile.h"
#import <Cordova/CDVAvailability.h>

#define kW3CMediaFormatHeight @"height"
#define kW3CMediaFormatWidth @"width"
#define kW3CMediaFormatCodecs @"codecs"
#define kW3CMediaFormatBitrate @"bitrate"
#define kW3CMediaFormatDuration @"duration"
#define kW3CMediaModeType @"type"

@implementation NSBundle (PluginExtensions)

+ (NSBundle*) pluginBundle:(CDVPlugin*)plugin {
    NSBundle* bundle = [NSBundle bundleWithPath: [[NSBundle mainBundle] pathForResource:NSStringFromClass([plugin class]) ofType: @"bundle"]];
    return bundle;
}
@end

#define PluginLocalizedString(plugin, key, comment) [[NSBundle pluginBundle:(plugin)] localizedStringForKey:(key) value:nil table:nil]

@implementation CDVImagePicker

@synthesize quality;
@synthesize callbackId;
@synthesize mimeType;

- (uint64_t)accessibilityTraits
{
    NSString* systemVersion = [[UIDevice currentDevice] systemVersion];

    if (([systemVersion compare:@"4.0" options:NSNumericSearch] != NSOrderedAscending)) { // this means system version is not less than 4.0
        return UIAccessibilityTraitStartsMediaSession;
    }

    return UIAccessibilityTraitNone;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIViewController*)childViewControllerForStatusBarHidden {
    return nil;
}

- (void)viewWillAppear:(BOOL)animated {
    SEL sel = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:sel]) {
        [self performSelector:sel withObject:nil afterDelay:0];
    }

    [super viewWillAppear:animated];
}

@end

@implementation CDVCapture
@synthesize inUse;

- (void)pluginInitialize
{
    self.inUse = NO;
}

- (void)captureAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }

    NSNumber* duration = [options objectForKey:@"duration"];
    // the default value of duration is 0 so use nil (no duration) if default value
    if (duration) {
        duration = [duration doubleValue] == 0 ? nil : duration;
    }
    CDVPluginResult* result = nil;

    if (NSClassFromString(@"AVAudioRecorder") == nil) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
    } else if (self.inUse == YES) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_APPLICATION_BUSY];
    } else {
        // all the work occurs here
        CDVAudioRecorderViewController* audioViewController = [[CDVAudioRecorderViewController alloc] initWithCommand:self duration:duration callbackId:callbackId];

        // Now create a nav controller and display the view...
        CDVAudioNavigationController* navController = [[CDVAudioNavigationController alloc] initWithRootViewController:audioViewController];

        self.inUse = YES;

        [self.viewController presentViewController:navController animated:YES completion:nil];
    }

    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)captureImage:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }

    // options could contain limit and mode neither of which are supported at this time
    // taking more than one picture (limit) is only supported if provide own controls via cameraOverlayView property
    // can support mode in OS

    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        NSLog(@"Capture.imageCapture: camera not available.");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    } else {
        if (pickerController == nil) {
            pickerController = [[CDVImagePicker alloc] init];
        }

        [self showAlertIfAccessProhibited];
        pickerController.delegate = self;
        pickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
        pickerController.allowsEditing = NO;
        if ([pickerController respondsToSelector:@selector(mediaTypes)]) {
            // iOS 3.0
            pickerController.mediaTypes = [NSArray arrayWithObjects:(NSString*)kUTTypeImage, nil];
        }

        /*if ([pickerController respondsToSelector:@selector(cameraCaptureMode)]){
            // iOS 4.0
            pickerController.cameraCaptureMode = UIImagePickerControllerCameraCaptureModePhoto;
            pickerController.cameraDevice = UIImagePickerControllerCameraDeviceRear;
            pickerController.cameraFlashMode = UIImagePickerControllerCameraFlashModeAuto;
        }*/
        // CDVImagePicker specific property
        pickerController.callbackId = callbackId;
        pickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
        [self.viewController presentViewController:pickerController animated:YES completion:nil];
    }
}

/* Process a still image from the camera.
 * IN:
 *  UIImage* image - the UIImage data returned from the camera
 *  NSString* callbackId
 */
- (CDVPluginResult*)processImage:(UIImage*)image type:(NSString*)mimeType forCallbackId:(NSString*)callbackId
{
    CDVPluginResult* result = nil;

    // save the image to photo album
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);

    NSData* data = nil;
    if (mimeType && [mimeType isEqualToString:@"image/png"]) {
        data = UIImagePNGRepresentation(image);
    } else {
        data = UIImageJPEGRepresentation(image, 0.5);
    }

    // write to temp directory and return URI
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];   // use file system temporary directory
    NSError* err = nil;
    NSFileManager* fileMgr = [[NSFileManager alloc] init];

    // generate unique file name
    NSString* filePath;
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/photo_%03d.jpg", docsPath, i++];
    } while ([fileMgr fileExistsAtPath:filePath]);

    if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
        if (err) {
            NSLog(@"Error saving image: %@", [err localizedDescription]);
        }
    } else {
        // create MediaFile object

        NSDictionary* fileDict = [self getMediaDictionaryFromPath:filePath ofType:mimeType];
        NSArray* fileArray = [NSArray arrayWithObject:fileDict];

        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
    }

    return result;
}

- (void)captureVideo:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }

    // options could contain limit, duration, quality and mode
    // taking more than one video (limit) is only supported if provide own controls via cameraOverlayView property
    NSNumber* duration = [options objectForKey:@"duration"];
    NSNumber* quality = [options objectForKey:@"quality"];
    NSString* mediaType = nil;

    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        // there is a camera, it is available, make sure it can do movies
        pickerController = [[CDVImagePicker alloc] init];

        NSArray* types = nil;
        if ([UIImagePickerController respondsToSelector:@selector(availableMediaTypesForSourceType:)]) {
            types = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
            // NSLog(@"MediaTypes: %@", [types description]);

            if ([types containsObject:(NSString*)kUTTypeMovie]) {
                mediaType = (NSString*)kUTTypeMovie;
            } else if ([types containsObject:(NSString*)kUTTypeVideo]) {
                mediaType = (NSString*)kUTTypeVideo;
            }
        }
    }
    if (!mediaType) {
        // don't have video camera return error
        NSLog(@"Capture.captureVideo: video mode not available.");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        pickerController = nil;
    } else {
        [self showAlertIfAccessProhibited];

        pickerController.delegate = self;
        pickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
        pickerController.allowsEditing = NO;
        // iOS 3.0
        pickerController.mediaTypes = [NSArray arrayWithObjects:mediaType, nil];

        if ([mediaType isEqualToString:(NSString*)kUTTypeMovie]){
            if (duration) {
                pickerController.videoMaximumDuration = [duration doubleValue];
            }
            //NSLog(@"pickerController.videoMaximumDuration = %f", pickerController.videoMaximumDuration);
        }

        // iOS 4.0
        if ([pickerController respondsToSelector:@selector(cameraCaptureMode)]) {
            pickerController.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;
            switch ((int) (quality ? [quality doubleValue] * 10 : -1)) {
                case 0:
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeLow;
                    break;
                case 5:
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeMedium;
                    break;
                case 10:
                default:
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeHigh;
                    break;
            }
            // pickerController.cameraDevice = UIImagePickerControllerCameraDeviceRear;
            // pickerController.cameraFlashMode = UIImagePickerControllerCameraFlashModeAuto;
        }
        // CDVImagePicker specific property
        pickerController.callbackId = callbackId;
        pickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
        [self.viewController presentViewController:pickerController animated:YES completion:nil];
    }
}

- (CDVPluginResult*)processVideo:(NSString*)moviePath forCallbackId:(NSString*)callbackId
{
    // save the movie to photo album (only avail as of iOS 3.1)

    /* don't need, it should automatically get saved
     NSLog(@"can save %@: %d ?", moviePath, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(moviePath));
    if (&UIVideoAtPathIsCompatibleWithSavedPhotosAlbum != NULL && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(moviePath) == YES) {
        NSLog(@"try to save movie");
        UISaveVideoAtPathToSavedPhotosAlbum(moviePath, nil, nil, nil);
        NSLog(@"finished saving movie");
    }*/
    // create MediaFile object
    NSDictionary* fileDict = [self getMediaDictionaryFromPath:moviePath ofType:nil];
    NSArray* fileArray = [NSArray arrayWithObject:fileDict];

    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
}

- (void)showAlertIfAccessProhibited
{
    if (![self hasCameraAccess]) {
        [self showPermissionsAlert];
    }
}

- (BOOL)hasCameraAccess
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

    return status != AVAuthorizationStatusDenied && status != AVAuthorizationStatusRestricted;
}

- (void)showPermissionsAlert
{
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]
        message:NSLocalizedString(@"Access to the camera has been prohibited; please enable it in the Settings app to continue.", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
    style:UIAlertActionStyleDefault
    handler:^(UIAlertAction * action)
    {
        [self returnNoPermissionError];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Settings", nil)
    style:UIAlertActionStyleDefault
    handler:^(UIAlertAction * action)
    {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]options:@{} completionHandler:nil];
        [self returnNoPermissionError];
    }]];
    [self.viewController presentViewController:alertController animated:YES completion:^{}];
}

- (void)returnNoPermissionError
{
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_PERMISSION_DENIED];

    [[pickerController presentingViewController] dismissViewControllerAnimated:YES completion:nil];
    [self.commandDelegate sendPluginResult:result callbackId:pickerController.callbackId];
    pickerController = nil;
    self.inUse = NO;
}

- (void)getMediaModes:(CDVInvokedUrlCommand*)command
{
    // NSString* callbackId = [command argumentAtIndex:0];
    // NSMutableDictionary* imageModes = nil;
    NSArray* imageArray = nil;
    NSArray* movieArray = nil;
    NSArray* audioArray = nil;

    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        // there is a camera, find the modes
        // can get image/jpeg or image/png from camera

        /* can't find a way to get the default height and width and other info
         * for images/movies taken with UIImagePickerController
         */
        NSDictionary* jpg = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
            [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
            @"image/jpeg", kW3CMediaModeType,
            nil];
        NSDictionary* png = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
            [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
            @"image/png", kW3CMediaModeType,
            nil];
        imageArray = [NSArray arrayWithObjects:jpg, png, nil];

        if ([UIImagePickerController respondsToSelector:@selector(availableMediaTypesForSourceType:)]) {
            NSArray* types = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];

            if ([types containsObject:(NSString*)kUTTypeMovie]) {
                NSDictionary* mov = [NSDictionary dictionaryWithObjectsAndKeys:
                    [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
                    [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
                    @"video/quicktime", kW3CMediaModeType,
                    nil];
                movieArray = [NSArray arrayWithObject:mov];
            }
        }
    }
    NSDictionary* modes = [NSDictionary dictionaryWithObjectsAndKeys:
        imageArray ? (NSObject*)                          imageArray:[NSNull null], @"image",
        movieArray ? (NSObject*)                          movieArray:[NSNull null], @"video",
        audioArray ? (NSObject*)                          audioArray:[NSNull null], @"audio",
        nil];

    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:modes options:0 error:nil];
    NSString* jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    NSString* jsString = [NSString stringWithFormat:@"navigator.device.capture.setSupportedModes(%@);", jsonStr];
    [self.commandDelegate evalJs:jsString];
}

- (void)getFormatData:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    // existence of fullPath checked on JS side
    NSString* fullPath = [command argumentAtIndex:0];
    // mimeType could be null
    NSString* mimeType = nil;

    if ([command.arguments count] > 1) {
        mimeType = [command argumentAtIndex:1];
    }
    BOOL bError = NO;
    CDVCaptureError errorCode = CAPTURE_INTERNAL_ERR;
    CDVPluginResult* result = nil;

    if (!mimeType || [mimeType isKindOfClass:[NSNull class]]) {
        // try to determine mime type if not provided
        id command = [self.commandDelegate getCommandInstance:@"File"];
        bError = !([command isKindOfClass:[CDVFile class]]);
        if (!bError) {
            CDVFile* cdvFile = (CDVFile*)command;
            mimeType = [cdvFile getMimeTypeFromPath:fullPath];
            if (!mimeType) {
                // can't do much without mimeType, return error
                bError = YES;
                errorCode = CAPTURE_INVALID_ARGUMENT;
            }
        }
    }
    if (!bError) {
        // create and initialize return dictionary
        NSMutableDictionary* formatData = [NSMutableDictionary dictionaryWithCapacity:5];
        [formatData setObject:[NSNull null] forKey:kW3CMediaFormatCodecs];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatBitrate];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatHeight];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatWidth];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatDuration];

        if ([mimeType rangeOfString:@"image/"].location != NSNotFound) {
            UIImage* image = [UIImage imageWithContentsOfFile:fullPath];
            if (image) {
                CGSize imgSize = [image size];
                [formatData setObject:[NSNumber numberWithInteger:imgSize.width] forKey:kW3CMediaFormatWidth];
                [formatData setObject:[NSNumber numberWithInteger:imgSize.height] forKey:kW3CMediaFormatHeight];
            }
        } else if (([mimeType rangeOfString:@"video/"].location != NSNotFound) && (NSClassFromString(@"AVURLAsset") != nil)) {
            NSURL* movieURL = [NSURL fileURLWithPath:fullPath];
            AVURLAsset* movieAsset = [[AVURLAsset alloc] initWithURL:movieURL options:nil];
            CMTime duration = [movieAsset duration];
            [formatData setObject:[NSNumber numberWithFloat:CMTimeGetSeconds(duration)]  forKey:kW3CMediaFormatDuration];

            NSArray* allVideoTracks = [movieAsset tracksWithMediaType:AVMediaTypeVideo];
            if ([allVideoTracks count] > 0) {
                AVAssetTrack* track = [[movieAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
                CGSize size = [track naturalSize];

                [formatData setObject:[NSNumber numberWithFloat:size.height] forKey:kW3CMediaFormatHeight];
                [formatData setObject:[NSNumber numberWithFloat:size.width] forKey:kW3CMediaFormatWidth];
                // not sure how to get codecs or bitrate???
                // AVMetadataItem
                // AudioFile
            } else {
                NSLog(@"No video tracks found for %@", fullPath);
            }
        } else if ([mimeType rangeOfString:@"audio/"].location != NSNotFound) {
            if (NSClassFromString(@"AVAudioPlayer") != nil) {
                NSURL* fileURL = [NSURL fileURLWithPath:fullPath];
                NSError* err = nil;

                AVAudioPlayer* avPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&err];
                if (!err) {
                    // get the data
                    [formatData setObject:[NSNumber numberWithDouble:[avPlayer duration]] forKey:kW3CMediaFormatDuration];
                    if ([avPlayer respondsToSelector:@selector(settings)]) {
                        NSDictionary* info = [avPlayer settings];
                        NSNumber* bitRate = [info objectForKey:AVEncoderBitRateKey];
                        if (bitRate) {
                            [formatData setObject:bitRate forKey:kW3CMediaFormatBitrate];
                        }
                    }
                } // else leave data init'ed to 0
            }
        }
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:formatData];
        // NSLog(@"getFormatData: %@", [formatData description]);
    }
    if (bError) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:(int)errorCode];
    }
    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (NSDictionary*)getMediaDictionaryFromPath:(NSString*)fullPath ofType:(NSString*)type
{
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSMutableDictionary* fileDict = [NSMutableDictionary dictionaryWithCapacity:6];

    CDVFile *fs = [self.commandDelegate getCommandInstance:@"File"];

    // Get canonical version of localPath
    NSURL *fileURL = [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", fullPath]];
    NSURL *resolvedFileURL = [fileURL URLByResolvingSymlinksInPath];
    NSString *path = [resolvedFileURL path];

    CDVFilesystemURL *url = [fs fileSystemURLforLocalPath:path];

    [fileDict setObject:[fullPath lastPathComponent] forKey:@"name"];
    [fileDict setObject:fullPath forKey:@"fullPath"];
    if (url) {
        [fileDict setObject:[url absoluteURL] forKey:@"localURL"];
    }
    // determine type
    NSString* mimeType = type;
    if (!mimeType) {
        id command = [self.commandDelegate getCommandInstance:@"File"];
        if ([command isKindOfClass:[CDVFile class]]) {
            CDVFile* cdvFile = (CDVFile*)command;
            mimeType = [cdvFile getMimeTypeFromPath:fullPath];
        }
    }
    [fileDict setObject:(mimeType != nil ? (NSObject*)mimeType : [NSNull null]) forKey:@"type"];
    NSDictionary* fileAttrs = [fileMgr attributesOfItemAtPath:fullPath error:nil];
    [fileDict setObject:[NSNumber numberWithUnsignedLongLong:[fileAttrs fileSize]] forKey:@"size"];
    NSDate* modDate = [fileAttrs fileModificationDate];
    NSNumber* msDate = [NSNumber numberWithDouble:[modDate timeIntervalSince1970] * 1000];
    [fileDict setObject:msDate forKey:@"lastModifiedDate"];

    return fileDict;
}

- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingImage:(UIImage*)image editingInfo:(NSDictionary*)editingInfo
{
    // older api calls new one
    [self imagePickerController:picker didFinishPickingMediaWithInfo:editingInfo];
}

/* Called when image/movie is finished recording.
 * Calls success or error code as appropriate
 * if successful, result  contains an array (with just one entry since can only get one image unless build own camera UI) of MediaFile object representing the image
 *      name
 *      fullPath
 *      type
 *      lastModifiedDate
 *      size
 */
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary*)info
{
    CDVImagePicker* cameraPicker = (CDVImagePicker*)picker;
    NSString* callbackId = cameraPicker.callbackId;

    [[picker presentingViewController] dismissViewControllerAnimated:YES completion:nil];

    CDVPluginResult* result = nil;

    UIImage* image = nil;
    NSString* mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if (!mediaType || [mediaType isEqualToString:(NSString*)kUTTypeImage]) {
        // mediaType is nil then only option is UIImagePickerControllerOriginalImage
        if ([UIImagePickerController respondsToSelector:@selector(allowsEditing)] &&
            (cameraPicker.allowsEditing && [info objectForKey:UIImagePickerControllerEditedImage])) {
            image = [info objectForKey:UIImagePickerControllerEditedImage];
        } else {
            image = [info objectForKey:UIImagePickerControllerOriginalImage];
        }
    }
    if (image != nil) {
        // mediaType was image
        result = [self processImage:image type:cameraPicker.mimeType forCallbackId:callbackId];
    } else if ([mediaType isEqualToString:(NSString*)kUTTypeMovie]) {
        // process video
        NSString* moviePath = [(NSURL *)[info objectForKey:UIImagePickerControllerMediaURL] path];
        if (moviePath) {
            result = [self processVideo:moviePath forCallbackId:callbackId];
        }
    }
    if (!result) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_INTERNAL_ERR];
    }
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    pickerController = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker
{
    CDVImagePicker* cameraPicker = (CDVImagePicker*)picker;
    NSString* callbackId = cameraPicker.callbackId;

    [[picker presentingViewController] dismissViewControllerAnimated:YES completion:nil];

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NO_MEDIA_FILES];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    pickerController = nil;
}

@end

@implementation CDVAudioNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    // delegate to CVDAudioRecorderViewController
    return [self.topViewController supportedInterfaceOrientations];
}

@end

@interface CDVAudioRecorderViewController () <UIAdaptivePresentationControllerDelegate> {
    UIStatusBarStyle _previousStatusBarStyle;
}
@end

@implementation CDVAudioRecorderViewController
@synthesize errorCode, callbackId, duration, captureCommand, doneButton, recordingView, recordButton, recordImage, stopRecordImage, timerLabel, avRecorder, avSession, pluginResult, timer, isTimed;

- (NSString*)resolveImageResource:(NSString*)resource
{
    NSString* systemVersion = [[UIDevice currentDevice] systemVersion];
    BOOL isLessThaniOS4 = ([systemVersion compare:@"4.0" options:NSNumericSearch] == NSOrderedAscending);

    // the iPad image (nor retina) differentiation code was not in 3.x, and we have to explicitly set the path
    // if user wants iPhone only app to run on iPad they must remove *~ipad.* images from CDVCapture.bundle
    if (isLessThaniOS4) {
        NSString* iPadResource = [NSString stringWithFormat:@"%@~ipad.png", resource];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad && [UIImage imageNamed:iPadResource]) {
            return iPadResource;
        } else {
            return [NSString stringWithFormat:@"%@.png", resource];
        }
    }

    return resource;
}

- (id)initWithCommand:(CDVCapture*)theCommand duration:(NSNumber*)theDuration callbackId:(NSString*)theCallbackId
{
    if ((self = [super init])) {
        self.captureCommand = theCommand;
        self.duration = theDuration;
        self.callbackId = theCallbackId;
        self.errorCode = CAPTURE_NO_MEDIA_FILES;
        self.isTimed = self.duration != nil;
        _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;

        return self;
    }

    return nil;
}

-(void) setupUI {

    CGRect viewRect = self.view.bounds;
    CGFloat topInset = self.navigationController.navigationBar.frame.size.height;
    CGFloat bottomInset = 10;
    self.navigationController.navigationBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.20 alpha:1];

    // make backgrounds
    NSString* microphoneResource = @"CDVCapture.bundle/microphone";

    BOOL isIphone5 = ([[UIScreen mainScreen] bounds].size.width == 568 && [[UIScreen mainScreen] bounds].size.height == 320) || ([[UIScreen mainScreen] bounds].size.height == 568 && [[UIScreen mainScreen] bounds].size.width == 320);
    if (isIphone5) {
        microphoneResource = @"CDVCapture.bundle/microphone-568h";
    }

    NSBundle* cdvBundle = [NSBundle bundleForClass:[CDVCapture class]];
    UIImage* microphone = [UIImage imageNamed:[self resolveImageResource:microphoneResource] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIImageView* microphoneView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, viewRect.size.width, viewRect.size.height)];
    [microphoneView setImage:microphone];
    [microphoneView setContentMode:UIViewContentModeScaleAspectFill];
    [microphoneView setUserInteractionEnabled:NO];
    [microphoneView setIsAccessibilityElement:NO];
    [self.view addSubview:microphoneView];

    // add bottom bar view
    UIImage* grayBkg = [UIImage imageNamed:[self resolveImageResource:@"CDVCapture.bundle/controls_bg"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIImageView* controls = [[UIImageView alloc] initWithFrame:CGRectMake(0, viewRect.size.height - grayBkg.size.height - bottomInset,
                                                                          viewRect.size.width, grayBkg.size.height + bottomInset)];
    [controls setImage:grayBkg];
    [controls setUserInteractionEnabled:NO];
    [controls setIsAccessibilityElement:NO];
    [self.view addSubview:controls];

    // make red recording background view
    UIImage* recordingBkg = [UIImage imageNamed:[self resolveImageResource:@"CDVCapture.bundle/recording_bg"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIColor* background = [UIColor colorWithPatternImage:recordingBkg];
    self.recordingView = [[UIView alloc] initWithFrame:CGRectMake(0, topInset, viewRect.size.width, recordingBkg.size.height)];
    [self.recordingView setBackgroundColor:background];
    [self.recordingView setHidden:YES];
    [self.recordingView setUserInteractionEnabled:NO];
    [self.recordingView setIsAccessibilityElement:NO];
    [self.view addSubview:self.recordingView];

    // add label
    self.timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, topInset, viewRect.size.width, recordingBkg.size.height)];
    [self.timerLabel setBackgroundColor:[UIColor clearColor]];
    [self.timerLabel setTextColor:[UIColor whiteColor]];
    [self.timerLabel setTextAlignment:NSTextAlignmentCenter];
    [self.timerLabel setText:@"0:00"];
    [self.timerLabel setAccessibilityHint:PluginLocalizedString(captureCommand, @"recorded time in minutes and seconds", nil)];
    self.timerLabel.accessibilityTraits |= UIAccessibilityTraitUpdatesFrequently;
    self.timerLabel.accessibilityTraits &= ~UIAccessibilityTraitStaticText;
    [self.view addSubview:self.timerLabel];

    // Add record button

    self.recordImage = [UIImage imageNamed:[self resolveImageResource:@"CDVCapture.bundle/record_button"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    self.stopRecordImage = [UIImage imageNamed:[self resolveImageResource:@"CDVCapture.bundle/stop_button"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    self.recordButton.accessibilityTraits |= [self accessibilityTraits];
    self.recordButton = [[UIButton alloc] initWithFrame:CGRectMake((viewRect.size.width - self.recordImage.size.width) / 2,
                                                                   microphoneView.frame.size.height - bottomInset - grayBkg.size.height +
                                                                    ((grayBkg.size.height - self.recordImage.size.height) / 2),
                                                                   self.recordImage.size.width, self.recordImage.size.height)];
    [self.recordButton setAccessibilityLabel:PluginLocalizedString(captureCommand, @"toggle audio recording", nil)];
    [self.recordButton setImage:recordImage forState:UIControlStateNormal];
    [self.recordButton addTarget:self action:@selector(processButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:recordButton];

    // make and add done button to navigation bar
    self.doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissAudioView:)];
    [self.doneButton setStyle:UIBarButtonItemStyleDone];
    self.navigationItem.rightBarButtonItem = self.doneButton;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
    NSError* error = nil;

    // Add delegate to catch the dismiss event
    self.navigationController.presentationController.delegate = self;

    if (self.avSession == nil) {
        // create audio session
        self.avSession = [AVAudioSession sharedInstance];
        if (error) {
            // return error if can't create recording audio session
            NSLog(@"error creating audio session: %@", [[error userInfo] description]);
            self.errorCode = CAPTURE_INTERNAL_ERR;
            [self dismissAudioView:nil];
        }
    }

    [self.avSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    
    // create file to record to in temporary dir

    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];   // use file system temporary directory
    NSError* err = nil;
    NSFileManager* fileMgr = [[NSFileManager alloc] init];

    // generate unique file name
    NSString* filePath;
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/audio_%03d.wav", docsPath, i++];
    } while ([fileMgr fileExistsAtPath:filePath]);

    NSURL* fileURL = [NSURL fileURLWithPath:filePath isDirectory:NO];

    // create AVAudioPlayer
    NSDictionary *recordSetting = [[NSMutableDictionary alloc] init];
    self.avRecorder = [[AVAudioRecorder alloc] initWithURL:fileURL settings:recordSetting error:&err];
    if (err) {
        NSLog(@"Failed to initialize AVAudioRecorder: %@\n", [err localizedDescription]);
        self.avRecorder = nil;
        // return error
        self.errorCode = CAPTURE_INTERNAL_ERR;
        [self dismissAudioView:nil];
    } else {
        self.avRecorder.delegate = self;
        [self.avRecorder prepareToRecord];
        self.recordButton.enabled = YES;
        self.doneButton.enabled = YES;
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    UIInterfaceOrientationMask orientation = UIInterfaceOrientationMaskPortrait;
    UIInterfaceOrientationMask supported = [captureCommand.viewController supportedInterfaceOrientations];

    orientation = orientation | (supported & UIInterfaceOrientationMaskPortraitUpsideDown);
    return orientation;
}

- (void)processButton:(id)sender
{
    if (self.avRecorder.recording) {
        // stop recording
        [self.avRecorder stop];
        self.isTimed = NO;  // recording was stopped via button so reset isTimed
        // view cleanup will occur in audioRecordingDidFinishRecording
    } else {
        // begin recording
        __block NSError* error = nil;

        __weak CDVAudioRecorderViewController* weakSelf = self;

        void (^startRecording)(void) = ^{
            [weakSelf.avSession setActive:YES error:&error];
            if (error) {
                // can't continue without active audio session
                weakSelf.errorCode = CAPTURE_INTERNAL_ERR;
                [weakSelf dismissAudioView:nil];
            } else {
                [weakSelf.recordButton setImage:weakSelf.stopRecordImage forState:UIControlStateNormal];
                weakSelf.recordButton.accessibilityTraits &= ~[self accessibilityTraits];
                [weakSelf.recordingView setHidden:NO];
                if (weakSelf.duration) {
                    weakSelf.isTimed = true;
                    [weakSelf.avRecorder recordForDuration:[weakSelf.duration doubleValue]];
                } else {
                    [weakSelf.avRecorder record];
                }
                [weakSelf.timerLabel setText:@"0.00"];
                weakSelf.timer = [NSTimer scheduledTimerWithTimeInterval:0.5f target:weakSelf selector:@selector(updateTime) userInfo:nil repeats:YES];
                weakSelf.doneButton.enabled = NO;
            }
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        };

        SEL rrpSel = NSSelectorFromString(@"requestRecordPermission:");
        if ([self.avSession respondsToSelector:rrpSel])
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.avSession performSelector:rrpSel withObject:^(BOOL granted){
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) {
                        startRecording();
                    } else {
                        NSLog(@"Error creating audio session, microphone permission denied.");
                        weakSelf.errorCode = CAPTURE_INTERNAL_ERR;
                        [weakSelf showMicrophonePermissionAlert];
                    }
                });
            }];
#pragma clang diagnostic pop
        } else {
            startRecording();
        }
    }
}

/*
 * helper method to clean up when stop recording
 */
- (void)stopRecordingCleanup
{
    if (self.avRecorder.recording) {
        [self.avRecorder stop];
    }
    [self.recordButton setImage:recordImage forState:UIControlStateNormal];
    self.recordButton.accessibilityTraits |= [self accessibilityTraits];
    [self.recordingView setHidden:YES];
    self.doneButton.enabled = YES;
    if (self.avSession) {
        // deactivate session so sounds can come through
        [self.avSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
        [self.avSession setActive:NO error:nil];
    }
    if (self.duration && self.isTimed) {
        // VoiceOver announcement so user knows timed recording has finished
        //BOOL isUIAccessibilityAnnouncementNotification = (&UIAccessibilityAnnouncementNotification != NULL);
        if (UIAccessibilityAnnouncementNotification) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500ull * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, PluginLocalizedString(self->captureCommand, @"timed recording complete", nil));
                });
        }
    } else {
        // issue a layout notification change so that VO will reannounce the button label when recording completes
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
}

- (void) showMicrophonePermissionAlert {
    UIAlertController* controller =
        [UIAlertController alertControllerWithTitle:PluginLocalizedString(captureCommand, @"Access denied", nil)
                                            message:PluginLocalizedString(captureCommand, @"Access to the microphone has been prohibited. Please enable it in the Settings app to continue.", nil)
                                     preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* actionOk = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [controller addAction:actionOk];

    UIAlertAction* actionSettings = [UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:[NSDictionary dictionary] completionHandler:nil];
    }];
    [controller addAction:actionSettings];

    __weak CDVAudioRecorderViewController* weakSelf = self;
    [weakSelf presentViewController:controller animated:true completion:nil];
}

- (void)dismissAudioView:(id)sender
{
    // called when done button pressed or when error condition to do cleanup and remove view
    [[self.captureCommand.viewController.presentedViewController presentingViewController] dismissViewControllerAnimated:YES completion:nil];

    if (!self.pluginResult) {
        // return error
        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:(int)self.errorCode];
    }

    self.avRecorder = nil;
    [self.avSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [self.avSession setActive:NO error:nil];
    [self.captureCommand setInUse:NO];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
    // return result
    [self.captureCommand.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)updateTime
{
    // update the label with the elapsed time
    [self.timerLabel setText:[self formatTime:self.avRecorder.currentTime]];
}

- (NSString*)formatTime:(int)interval
{
    // is this format universal?
    int secs = interval % 60;
    int min = interval / 60;

    if (interval < 60) {
        return [NSString stringWithFormat:@"0:%02d", interval];
    } else {
        return [NSString stringWithFormat:@"%d:%02d", min, secs];
    }
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder*)recorder successfully:(BOOL)flag
{
    // may be called when timed audio finishes - need to stop time and reset buttons
    [self.timer invalidate];
    [self stopRecordingCleanup];

    // generate success result
    if (flag) {
        NSString* filePath = [avRecorder.url path];
        // NSLog(@"filePath: %@", filePath);
        NSDictionary* fileDict = [captureCommand getMediaDictionaryFromPath:filePath ofType:nil];
        NSArray* fileArray = [NSArray arrayWithObject:fileDict];

        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
    } else {
        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder*)recorder error:(NSError*)error
{
    [self.timer invalidate];
    [self stopRecordingCleanup];

    NSLog(@"error recording audio");
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
    [self dismissAudioView:nil];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self dismissAudioView:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setupUI];
}

@end
