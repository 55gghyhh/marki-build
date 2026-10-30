// =============================================================================
//  MarkiFake  —  markki.cn / 马克水印相机 16.4.1  一体化造假 Tweak
// =============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <MapKit/MapKit.h>
#import <PhotosUI/PhotosUI.h>
#include <dlfcn.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <math.h>

#define MKSEL(name) NSSelectorFromString(@#name)
#define MK_CAT2(a, b) a##b
#define MK_CAT(a, b)  MK_CAT2(a, b)

static volatile BOOL gAdBlockActive = NO;
static void MKAlert(NSString *title, NSString *msg);
static void MKInstallAdBlock(void);
static void MKInstallDeferredHooks(void);

static NSString *MKLogFilePath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (!dir) dir = NSTemporaryDirectory();
        p = [dir stringByAppendingPathComponent:@"marki_fake.log"];
    });
    return p;
}

static void MKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MKFake] %@", msg);
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.mkf.log", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        @autoreleasepool {
            double t = CFAbsoluteTimeGetCurrent() + 978307200.0;
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n", t, msg];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *path = MKLogFilePath();
            struct stat st;
            if (stat(path.UTF8String, &st) == 0 && st.st_size > 512 * 1024) { [fm removeItemAtPath:path error:NULL]; }
            if (![fm fileExistsAtPath:path]) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) return;
            @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
            @catch (NSException *e) { NSLog(@"[MKFake] 写日志失败: %@", e.reason); }
        }
    });
}

#define MKLOG_ONCE(fmt, ...) do { \
    static BOOL MK_CAT(_mk_once_, __LINE__) = NO; \
    if (!MK_CAT(_mk_once_, __LINE__)) { \
        MK_CAT(_mk_once_, __LINE__) = YES; \
        MKLog(fmt, ##__VA_ARGS__); \
    } \
} while (0)

@interface MKFakeCfg : NSObject
@property (nonatomic, assign) double    lat;
@property (nonatomic, assign) double    lng;
@property (nonatomic, copy)   NSString *addr;
@property (nonatomic, copy)   NSString *imgPath;
@property (nonatomic, assign) BOOL      locOn;
@property (nonatomic, assign) BOOL      photoOn;
@property (nonatomic, assign) BOOL      photoAlways;
@property (nonatomic, assign) double    photoUntil;
@property (nonatomic, assign) BOOL      timeOn;
@property (nonatomic, copy)   NSString *fakeTime;
@property (nonatomic, assign) BOOL      wxOn;
@property (nonatomic, copy)   NSString *wxText;
@property (nonatomic, assign) long long wxTemp;
@property (nonatomic, assign) BOOL      antiOn;
@property (nonatomic, assign) BOOL      fill;
@property (nonatomic, assign) BOOL      flipY;
@property (nonatomic, assign) BOOL      fab;
@property (nonatomic, assign) BOOL      adBlockOn;
@property (nonatomic, assign) BOOL      safeClockOn;
@property (nonatomic, assign) BOOL      verifyOn;          // 验真对齐总开关
@property (nonatomic, copy)   NSString *verifyExifText;    // 注入的 ImageDescription/Caption，留空=抄真图
@property (nonatomic, assign) NSInteger layer;
+ (instancetype)shared;
- (void)load;
- (void)save;
@end

@implementation MKFakeCfg
+ (instancetype)shared {
    static MKFakeCfg *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MKFakeCfg new]; [s load]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lat = 39.9042; _lng = 116.4074; _addr = @"北京市东城区东长安街"; _imgPath = @"@latest";
        _fakeTime = @"2026-10-30 09:15:00"; _wxText = @"晴"; _wxTemp = 26;
        _antiOn = YES; _fill = YES; _flipY = NO; _fab = YES;
        _adBlockOn = NO;
        _safeClockOn = NO;
        _verifyOn = YES;
        _verifyExifText = @"";
        _layer = 1;
    }
    return self;
}
- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"mk.lat"])       self.lat = [d doubleForKey:@"mk.lat"];
    if ([d objectForKey:@"mk.lng"])       self.lng = [d doubleForKey:@"mk.lng"];
    if ([d stringForKey:@"mk.addr"])      self.addr = [d stringForKey:@"mk.addr"];
    if ([d stringForKey:@"mk.img"])       self.imgPath = [d stringForKey:@"mk.img"];
    if ([d stringForKey:@"mk.fakeTime"])  self.fakeTime = [d stringForKey:@"mk.fakeTime"];
    if ([d stringForKey:@"mk.wxText"])    self.wxText = [d stringForKey:@"mk.wxText"];
    if ([d objectForKey:@"mk.wxTemp"])    self.wxTemp = [d integerForKey:@"mk.wxTemp"];
    if ([d objectForKey:@"mk.antiOn"])    self.antiOn = [d boolForKey:@"mk.antiOn"];
    if ([d objectForKey:@"mk.fill"])      self.fill = [d boolForKey:@"mk.fill"];
    if ([d objectForKey:@"mk.flipY"])     self.flipY = [d boolForKey:@"mk.flipY"];
    if ([d objectForKey:@"mk.fab"])       self.fab = [d boolForKey:@"mk.fab"];
    if ([d objectForKey:@"mk.adBlock"])   self.adBlockOn = [d boolForKey:@"mk.adBlock"];
    if ([d objectForKey:@"mk.safeClock"]) self.safeClockOn = [d boolForKey:@"mk.safeClock"];
    if ([d objectForKey:@"mk.verifyOn"])  self.verifyOn = [d boolForKey:@"mk.verifyOn"];
    if ([d stringForKey:@"mk.verifyExif"]) self.verifyExifText = [d stringForKey:@"mk.verifyExif"];
    if ([d objectForKey:@"mk.layer"])     self.layer = [d integerForKey:@"mk.layer"];
    self.locOn       = [d boolForKey:@"mk.locOn"];
    self.photoOn     = [d boolForKey:@"mk.photoOn"];
    self.photoAlways = [d boolForKey:@"mk.photoAlways"];
    self.photoUntil  = [d doubleForKey:@"mk.photoUntil"];
    self.timeOn      = [d boolForKey:@"mk.timeOn"];
    self.wxOn        = [d boolForKey:@"mk.wxOn"];
}
- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:self.lat forKey:@"mk.lat"];
    [d setDouble:self.lng forKey:@"mk.lng"];
    [d setObject:self.addr     forKey:@"mk.addr"];
    [d setObject:self.imgPath  forKey:@"mk.img"];
    [d setObject:self.fakeTime forKey:@"mk.fakeTime"];
    [d setObject:self.wxText   forKey:@"mk.wxText"];
    [d setInteger:self.wxTemp  forKey:@"mk.wxTemp"];
    [d setBool:self.locOn       forKey:@"mk.locOn"];
    [d setBool:self.photoOn     forKey:@"mk.photoOn"];
    [d setBool:self.photoAlways forKey:@"mk.photoAlways"];
    [d setDouble:self.photoUntil forKey:@"mk.photoUntil"];
    [d setBool:self.timeOn   forKey:@"mk.timeOn"];
    [d setBool:self.wxOn     forKey:@"mk.wxOn"];
    [d setBool:self.antiOn   forKey:@"mk.antiOn"];
    [d setBool:self.fill     forKey:@"mk.fill"];
    [d setBool:self.flipY    forKey:@"mk.flipY"];
    [d setBool:self.fab      forKey:@"mk.fab"];
    [d setBool:self.adBlockOn forKey:@"mk.adBlock"];
    [d setBool:self.safeClockOn forKey:@"mk.safeClock"];
    [d setBool:self.verifyOn forKey:@"mk.verifyOn"];
    [d setObject:self.verifyExifText ?: @"" forKey:@"mk.verifyExif"];
    [d setInteger:self.layer forKey:@"mk.layer"];
    [d synchronize];
    MKLog(@"配置已保存 loc=%d(%.6f,%.6f) photo=%d(%@) time=%d(%@) wx=%d(%@) anti=%d layer=%ld fill=%d flip=%d",
          self.locOn, self.lat, self.lng, self.photoOn, self.imgPath, self.timeOn, self.fakeTime, self.wxOn, self.wxText, self.antiOn, (long)self.layer, self.fill, self.flipY);
}
@end

static MKFakeCfg *CFG(void) { return [MKFakeCfg shared]; }
static double MKUnixNow(void) { return CFAbsoluteTimeGetCurrent() + 978307200.0; }

static IMP MKHook(Class cls, SEL sel, IMP newIMP, const char *label) {
    if (!cls) { MKLog(@"✗ hook 跳过：类不存在  (%s)", label); return NULL; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m)   { MKLog(@"✗ hook 跳过：方法不存在 (%s)", label); return NULL; }
    IMP old = method_getImplementation(m);
    if (old == newIMP) { MKLog(@"· hook 已存在   (%s)", label); return old; }
    method_setImplementation(m, newIMP);
    MKLog(@"✓ hook %s   old=%p → new=%p", label, (void *)old, (void *)newIMP);
    return old;
}
static IMP MKHookClass(Class cls, SEL sel, IMP newIMP, const char *label) {
    if (!cls) { MKLog(@"✗ hook 跳过：类不存在  (%s)", label); return NULL; }
    Method m = class_getClassMethod(cls, sel);
    if (!m)   { MKLog(@"✗ hook 跳过：类方法不存在 (%s)", label); return NULL; }
    IMP old = method_getImplementation(m);
    if (old == newIMP) return old;
    method_setImplementation(m, newIMP);
    MKLog(@"✓ hook +%s   old=%p → new=%p", label, (void *)old, (void *)newIMP);
    return old;
}
static char MKRetType(Method m) { char buf[32] = {0}; method_getReturnType(m, buf, sizeof(buf)); return buf[0]; }

static NSString *MKFourCC(OSType fmt) {
    char c[5]; c[0] = (char)((fmt >> 24) & 0xFF); c[1] = (char)((fmt >> 16) & 0xFF);
    c[2] = (char)((fmt >> 8) & 0xFF); c[3] = (char)(fmt & 0xFF); c[4] = 0;
    for (int i = 0; i < 4; i++) { if (c[i] < 32 || c[i] > 126) c[i] = '?'; }
    return [NSString stringWithFormat:@"'%s'(0x%08X)", c, (unsigned)fmt];
}
static BOOL MKIsYUV(OSType fmt) {
    return fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8Planar || fmt == kCVPixelFormatType_420YpCbCr8PlanarFullRange || fmt == kCVPixelFormatType_422YpCbCr8 || fmt == kCVPixelFormatType_422YpCbCr8_yuvs;
}
static BOOL MKIs32RGBA(OSType fmt) { return fmt == kCVPixelFormatType_32BGRA; }

static void *MKBufferAttachments(CVPixelBufferRef pb) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFDictionaryRef d = CVBufferGetAttachments((CVBufferRef)pb, kCVAttachmentMode_ShouldPropagate);
#pragma clang diagnostic pop
    return (void *)d;
}

static UIImage  *gSwapImg = nil;
static NSString *gSwapKey = nil;
static CFAbsoluteTime gSwapLoadedAt = 0;
static BOOL      gSwapFetching = NO;
#define MK_MAX_PIXEL 4096.0

static UIImage *MKNormalizeUIImage(UIImage *img) {
    if (!img) return nil;
    if (img.imageOrientation == UIImageOrientationUp) return img;
    @try {
        UIGraphicsBeginImageContextWithOptions(img.size, NO, 1.0);
        [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (out) return out;
    } @catch (NSException *e) { MKLog(@"方向修正失败: %@", e.reason); }
    return img;
}
static UIImage *MKDownsampleFile(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES, (id)kCGImageSourceCreateThumbnailWithTransform : @YES, (id)kCGImageSourceThumbnailMaxPixelSize : @(MK_MAX_PIXEL) };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return [UIImage imageWithContentsOfFile:path];
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}
static UIImage *MKLatestAssetImage(void) {
    if (gSwapFetching) return nil;
    gSwapFetching = YES;
    __block UIImage *out = nil;
    @try {
        PHFetchOptions *opt = [PHFetchOptions new];
        opt.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        PHFetchResult<PHAsset *> *res = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:opt];
        PHAsset *asset = res.firstObject;
        if (asset) {
            PHImageRequestOptions *ro = [PHImageRequestOptions new];
            ro.synchronous = YES; ro.networkAccessAllowed = YES; ro.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat; ro.resizeMode = PHImageRequestOptionsResizeModeExact;
            [[PHImageManager defaultManager] requestImageForAsset:asset targetSize:CGSizeMake(MK_MAX_PIXEL, MK_MAX_PIXEL) contentMode:PHImageContentModeAspectFit options:ro resultHandler:^(UIImage *img, NSDictionary *info) { out = img; }];
        }
    } @catch (NSException *e) {}
    gSwapFetching = NO;
    return MKNormalizeUIImage(out);
}
static UIImage *MKLoadSwapImage(BOOL force, BOOL allowFetch) {
    MKFakeCfg *c = CFG();
    NSString *key = c.imgPath.length ? c.imgPath : @"@latest";
    if (!force && gSwapImg && [gSwapKey isEqualToString:key] && (CFAbsoluteTimeGetCurrent() - gSwapLoadedAt) < 20.0) return gSwapImg;
    UIImage *img = nil;
    if ([key isEqualToString:@"@latest"]) {
        if ([NSThread isMainThread] || !allowFetch) return gSwapImg;
        img = MKLatestAssetImage();
    } else {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:key]) { img = MKDownsampleFile(key); }
    }
    if (!img) return gSwapImg;
    gSwapImg = img; gSwapKey = key; gSwapLoadedAt = CFAbsoluteTimeGetCurrent();
    return gSwapImg;
}
static void MKPrefetchSwapImage(void) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ MKLoadSwapImage(YES, YES); }); }
static BOOL MKPhotoArmed(void) {
    MKFakeCfg *c = CFG();
    if (!c.photoOn) return NO;
    if (c.photoAlways) return YES;
    if (c.photoUntil <= 0) return NO;
    return MKUnixNow() < c.photoUntil;
}

static CVPixelBufferRef gLastPB = NULL;
static double gLastToken = -1;
static CFAbsoluteTime gLastSwapAt = 0;

static void MKDrawCGImage(CGContextRef ctx, CGImageRef cg, size_t w, size_t h) {
    CGFloat iw = (CGFloat)CGImageGetWidth(cg); CGFloat ih = (CGFloat)CGImageGetHeight(cg);
    if (iw <= 0 || ih <= 0) return;
    CGFloat s  = CFG().fill ? MAX((CGFloat)w / iw, (CGFloat)h / ih) : MIN((CGFloat)w / iw, (CGFloat)h / ih);
    CGFloat dw = iw * s, dh = ih * s; CGFloat dx = ((CGFloat)w - dw) * 0.5f; CGFloat dy = ((CGFloat)h - dh) * 0.5f;
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1); CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSaveGState(ctx);
    if (CFG().flipY) { CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1); }
    CGContextDrawImage(ctx, CGRectMake(dx, dy, dw, dh), cg);
    CGContextRestoreGState(ctx);
}
static BOOL MKDrawIntoBGRA(CVPixelBufferRef pb, CGImageRef cg, size_t w, size_t h) {
    CVReturn rc = CVPixelBufferLockBaseAddress(pb, 0);
    if (rc != kCVReturnSuccess) return NO;
    BOOL ok = NO; void  *base = CVPixelBufferGetBaseAddress(pb); size_t bpr  = CVPixelBufferGetBytesPerRow(pb);
    if (base && bpr >= w * 4) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        if (ctx) { MKDrawCGImage(ctx, cg, w, h); CGContextRelease(ctx); ok = YES; }
        CGColorSpaceRelease(cs);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return ok;
}
static BOOL MKDrawIntoCI(CVPixelBufferRef pb, CGImageRef cg, size_t w, size_t h) {
    @autoreleasepool {
        CIImage *src = [CIImage imageWithCGImage:cg];
        if (!src) return NO;
        CGRect ext = src.extent;
        CGFloat s = CFG().fill ? MAX((CGFloat)w / ext.size.width, (CGFloat)h / ext.size.height) : MIN((CGFloat)w / ext.size.width, (CGFloat)h / ext.size.height);
        CIImage *scaled = [src imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
        CGRect se = scaled.extent;
        CGAffineTransform tr = CGAffineTransformMakeTranslation(((CGFloat)w - se.size.width) * 0.5f - se.origin.x, ((CGFloat)h - se.size.height) * 0.5f - se.origin.y);
        CIImage *pos = [scaled imageByApplyingTransform:tr];
        CIImage *bg = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]] imageByCroppingToRect:CGRectMake(0, 0, w, h)];
        CIImage *out = [pos imageByCompositingOverImage:bg];
        BOOL soft = (CVPixelBufferGetIOSurface(pb) == NULL);
        CIContext *ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer : @(soft) }];
        if (!ctx) return NO;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        @try { [ctx render:out toCVPixelBuffer:pb bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h) colorSpace:cs]; }
        @catch (NSException *e) { CGColorSpaceRelease(cs); return NO; }
        CGColorSpaceRelease(cs);
        return YES;
    }
}
static BOOL MKSwapPixelBuffer(CVPixelBufferRef pb, double token, const char *who) {
    if (!pb) return NO;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    if (pb == gLastPB && token == gLastToken && (t0 - gLastSwapAt) < 3.0) return YES;
    UIImage *img = MKLoadSwapImage(NO, NO);
    if (!img) return NO;
    CGImageRef cg = img.CGImage;
    if (!cg) return NO;
    size_t w = CVPixelBufferGetWidth(pb); size_t h = CVPixelBufferGetHeight(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    BOOL ok = NO;
    if (MKIs32RGBA(fmt)) { ok = MKDrawIntoBGRA(pb, cg, w, h); if (!ok) ok = MKDrawIntoCI(pb, cg, w, h); }
    else { ok = MKDrawIntoCI(pb, cg, w, h); }
    if (ok) { gLastPB = pb; gLastToken = token; gLastSwapAt = t0; }
    return ok;
}

static IMP o_vsInit  = NULL; static IMP o_photoCb = NULL;
static id h_vsInit(id self, SEL _cmd, CVPixelBufferRef pb, double ts) {
    if (MKPhotoArmed()) { @try { MKSwapPixelBuffer(pb, ts, "GLVideoSample"); } @catch (NSException *e) {} }
    return ((id (*)(id, SEL, CVPixelBufferRef, double))o_vsInit)(self, _cmd, pb, ts);
}
static void h_photoCb(id self, SEL _cmd, id output, id photo, id error) {
    if (CFG().layer != 1 && MKPhotoArmed()) {
        @try { AVCapturePhoto *p = (AVCapturePhoto *)photo; CVPixelBufferRef pb = [p pixelBuffer]; double ts = CMTimeGetSeconds(p.timestamp); if (pb) MKSwapPixelBuffer(pb, ts, "AVCapturePhoto"); } @catch (NSException *e) {}
    }
    ((void (*)(id, SEL, id, id, id))o_photoCb)(self, _cmd, output, photo, error);
}
static void MKInstallCameraHooks(void) {
    Class vs = objc_getClass("GLVideoSample");
    if (vs) { o_vsInit = MKHook(vs, MKSEL(initWithPixelBuffer:timeStamp:), (IMP)h_vsInit, "Camera_GLVideoSample"); }
    Class vd = objc_getClass("GLVideoDevice");
    if (vd) { o_photoCb = MKHook(vd, MKSEL(captureOutput:didFinishProcessingPhoto:error:), (IMP)h_photoCb, "Camera_GLVideoDevice"); }
}

static CLLocation *gFakeLoc = nil; static double gFakeLat = -9999, gFakeLng = -9999;
static CLLocation *MKFakeLocation(void) {
    MKFakeCfg *c = CFG();
    if (gFakeLoc && fabs(gFakeLat - c.lat) < 1e-9 && fabs(gFakeLng - c.lng) < 1e-9) return gFakeLoc;
    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(c.lat, c.lng) altitude:50.0 horizontalAccuracy:5.0 verticalAccuracy:5.0 timestamp:[NSDate date]];
    gFakeLoc = loc; gFakeLat = c.lat; gFakeLng = c.lng;
    return gFakeLoc;
}
static void MKSpoofModel(id model) {
    if (!model || !CFG().locOn) return;
    @try { [model setValue:@(CFG().lat) forKey:@"latitude"]; [model setValue:@(CFG().lng) forKey:@"longitude"]; } @catch (NSException *e) { return; }
    if (CFG().addr.length) {
        @try {
            if ([model respondsToSelector:MKSEL(setAddress:)]) [model setValue:CFG().addr forKey:@"address"];
            else if ([model respondsToSelector:MKSEL(setNowAllAddress:)]) [model setValue:CFG().addr forKey:@"nowAllAddress"];
        } @catch (NSException *e) {}
    }
}
static IMP o_mgrGetRecent = NULL, o_mgrSetRecent = NULL, o_mgrCheckAuth = NULL, o_infoLat = NULL, o_infoLng = NULL, o_objLat = NULL, o_objLng = NULL, o_locMgrLocation = NULL, o_locCoord = NULL, o_locSource = NULL;
static id h_mgrGetRecent(id self, SEL _cmd) {
    id r = ((id (*)(id, SEL))o_mgrGetRecent)(self, _cmd);
    if (!CFG().locOn) return r;
    if (!r) { Class c = objc_getClass("MKLocationInfo"); if (c) { id m = [[c alloc] init]; MKSpoofModel(m); return m; } return nil; }
    MKSpoofModel(r); return r;
}
static void h_mgrSetRecent(id self, SEL _cmd, id v) { MKSpoofModel(v); ((void (*)(id, SEL, id))o_mgrSetRecent)(self, _cmd, v); }
static BOOL h_mgrCheckAuth(id self, SEL _cmd) { if (CFG().locOn) return YES; return ((BOOL (*)(id, SEL))o_mgrCheckAuth)(self, _cmd); }
static double h_infoLat(id self, SEL _cmd) { return CFG().locOn ? CFG().lat : ((double (*)(id, SEL))o_infoLat)(self, _cmd); }
static double h_infoLng(id self, SEL _cmd) { return CFG().locOn ? CFG().lng : ((double (*)(id, SEL))o_infoLng)(self, _cmd); }
static double h_objLat(id self, SEL _cmd) { return CFG().locOn ? CFG().lat : ((double (*)(id, SEL))o_objLat)(self, _cmd); }
static double h_objLng(id self, SEL _cmd) { return CFG().locOn ? CFG().lng : ((double (*)(id, SEL))o_objLng)(self, _cmd); }
static id h_locMgrLocation(id self, SEL _cmd) { if (CFG().locOn) { CLLocation *f = MKFakeLocation(); if (f) return f; } return ((id (*)(id, SEL))o_locMgrLocation)(self, _cmd); }
static CLLocationCoordinate2D h_locCoord(id self, SEL _cmd) { if (CFG().locOn) return CLLocationCoordinate2DMake(CFG().lat, CFG().lng); return ((CLLocationCoordinate2D (*)(id, SEL))o_locCoord)(self, _cmd); }
static id h_locSource(id self, SEL _cmd) { if (CFG().antiOn && CFG().locOn) return nil; return ((id (*)(id, SEL))o_locSource)(self, _cmd); }
static void MKHookDoubleGetter(Class cls, SEL sel, IMP fn, IMP *slot, const char *label) {
    if (!cls) return; Method m = class_getInstanceMethod(cls, sel); if (!m) return; if (MKRetType(m) != 'd') return; *slot = MKHook(cls, sel, fn, label);
}
static void MKInstallLocationHooks(void) {
    Class mgr = objc_getClass("MKLocationManager");
    if (mgr) {
        o_mgrGetRecent = MKHook(mgr, MKSEL(getRecentLocation), (IMP)h_mgrGetRecent, "Location_Get");
        o_mgrSetRecent = MKHook(mgr, MKSEL(setRecentLocation:), (IMP)h_mgrSetRecent, "Location_Set");
        o_mgrCheckAuth = MKHook(mgr, MKSEL(checkLocationAuthorization), (IMP)h_mgrCheckAuth, "Location_Auth");
    }
    MKHookDoubleGetter(objc_getClass("MKLocationInfo"), MKSEL(latitude), (IMP)h_infoLat, &o_infoLat, "Loc_Info_Lat");
    MKHookDoubleGetter(objc_getClass("MKLocationInfo"), MKSEL(longitude), (IMP)h_infoLng, &o_infoLng, "Loc_Info_Lng");
    Class obj = objc_getClass("_TtC8marki_cn16MKLocationObject");
    MKHookDoubleGetter(obj, MKSEL(latitude), (IMP)h_objLat, &o_objLat, "Loc_Obj_Lat");
    MKHookDoubleGetter(obj, MKSEL(longitude), (IMP)h_objLng, &o_objLng, "Loc_Obj_Lng");
    o_locMgrLocation = MKHook(objc_getClass("CLLocationManager"), @selector(location), (IMP)h_locMgrLocation, "Loc_Mgr_Loc");
    o_locCoord = MKHook(objc_getClass("CLLocation"), @selector(coordinate), (IMP)h_locCoord, "Loc_Coord");
    o_locSource = MKHook(objc_getClass("CLLocation"), @selector(sourceInformation), (IMP)h_locSource, "Loc_Source");
}

static IMP o_simSoftware = NULL, o_bmkMockProb = NULL, o_bmkMgrMockProb = NULL, o_tnkMockGPS = NULL, o_bizMockLimit = NULL, o_realIsMock = NULL, o_distance = NULL;
static BOOL h_simSoftware(id self, SEL _cmd) { if (CFG().antiOn) return NO; return ((BOOL (*)(id, SEL))o_simSoftware)(self, _cmd); }
static int h_bmkMockProb(id self, SEL _cmd) { if (CFG().antiOn) return 0; return ((int (*)(id, SEL))o_bmkMockProb)(self, _cmd); }
static int h_bmkMgrMockProb(id self, SEL _cmd) { if (CFG().antiOn) return 0; return ((int (*)(id, SEL))o_bmkMgrMockProb)(self, _cmd); }
static BOOL h_tnkMockGPS(id self, SEL _cmd) { if (CFG().antiOn) return NO; return ((BOOL (*)(id, SEL))o_tnkMockGPS)(self, _cmd); }
static long long h_bizMockLimit(id self, SEL _cmd) { if (CFG().antiOn) return 100; return ((long long (*)(id, SEL))o_bizMockLimit)(self, _cmd); }
static BOOL h_realIsMock(id self, SEL _cmd) { if (CFG().antiOn) return NO; return ((BOOL (*)(id, SEL))o_realIsMock)(self, _cmd); }
static double h_distance(id self, SEL _cmd, CLLocation *other) { if (CFG().antiOn && CFG().locOn) return 0.0; return ((double (*)(id, SEL, id))o_distance)(self, _cmd, other); }
static void MKInstallAntiCheatHooks(void) {
    o_simSoftware = MKHook(objc_getClass("CLLocationSourceInformation"), @selector(isSimulatedBySoftware), (IMP)h_simSoftware, "Anti_SimSoftware");
    o_bmkMockProb = MKHook(objc_getClass("BMKLocation"), MKSEL(mockProbability), (IMP)h_bmkMockProb, "Anti_BMKProb");
    o_bmkMgrMockProb = MKHook(objc_getClass("BMKLocationManager"), MKSEL(getMockLocationProbability), (IMP)h_bmkMgrMockProb, "Anti_BMKMgrProb");
    o_tnkMockGPS = MKHook(objc_getClass("TNKLocation"), MKSEL(mockGPS), (IMP)h_tnkMockGPS, "Anti_TNKMock");
    o_bizMockLimit = MKHook(objc_getClass("BusinessConfigCenter"), MKSEL(mockLimitProbability), (IMP)h_bizMockLimit, "Anti_BizMock");
    o_realIsMock = MKHook(objc_getClass("_TtC8marki_cn19LocationRealManager"), MKSEL(isMockLocation), (IMP)h_realIsMock, "Anti_RealMock");
    o_distance = MKHook(objc_getClass("CLLocation"), @selector(distanceFromLocation:), (IMP)h_distance, "Anti_Distance");
}

static NSDate *MKParseFakeTime(NSString *s);
static volatile int  gTimeDelta = 0;
static BOOL          gClockHooked = NO;
static volatile BOOL gClockActive = NO;

static time_t (*gOrigTime)(time_t *) = NULL;
static int    (*gOrigGettimeofday)(struct timeval *, void *) = NULL;
static int    (*gOrigClockGettime)(clockid_t, struct timespec *) = NULL;

static time_t MK_time(time_t *out) {
    time_t v = gOrigTime ? gOrigTime(out) : 0;
    if (gClockActive) v += (time_t)gTimeDelta;
    if (out) *out = v;
    return v;
}
static int MK_gettimeofday(struct timeval *tv, void *tz) {
    int rc = gOrigGettimeofday ? gOrigGettimeofday(tv, tz) : -1;
    if (rc == 0 && tv && gClockActive) tv->tv_sec += gTimeDelta;
    return rc;
}
static int MK_clock_gettime(clockid_t cid, struct timespec *ts) {
    int rc = gOrigClockGettime ? gOrigClockGettime(cid, ts) : -1;
    if (rc == 0 && ts && cid == CLOCK_REALTIME && gClockActive) ts->tv_sec += gTimeDelta;
    return rc;
}

#ifndef INDIRECT_SYMBOL_LOCAL
#define INDIRECT_SYMBOL_LOCAL 0x80000000
#endif
#ifndef INDIRECT_SYMBOL_ABS
#define INDIRECT_SYMBOL_ABS 0x40000000
#endif

#define MK_MAX_REBINDS 128

// 一条改写记录。group 用来区分「时钟」和「EXIF」两批，还原时互不干扰。
typedef struct { void **slot; void *orig; int group; } MKRebind;
static MKRebind gRebinds[MK_MAX_REBINDS];
static int      gRebindCount = 0;

#define MK_GROUP_CLOCK 1
#define MK_GROUP_EXIF  2

// 要改写的符号描述
typedef struct { const char *name; void *rep; void **origSlot; int group; } MKHookEntry;

// 返回 NO = 这块内存受保护、改不了。调用方必须跳过 —— 上一版忽略了 vm_protect 的
// 返回值，在系统库/共享缓存页上照样往下写，直接触发内存保护崩溃。
static BOOL MKMakeWritable(void *addr, size_t len) {
    if (!addr || !len) return NO;
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(getpagesize() - 1);
    uintptr_t end  = (uintptr_t)addr + len;
    kern_return_t kr = vm_protect(mach_task_self(), page, end - page, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        MKLog(@"✗ vm_protect 失败 kr=0x%x page=%p len=%zu → 跳过", kr, (void *)page, (size_t)(end - page));
        return NO;
    }
    return YES;
}

// ---- 模块白名单：只允许动这三个，系统库一个字节都不碰 ----
static BOOL MKImageAllowed(const char *path) {
    if (!path) return NO;
    // 硬拒绝：系统库、系统框架、dyld 共享缓存、开发者目录
    if (strncmp(path, "/usr/lib/", 9) == 0)          return NO;
    if (strncmp(path, "/System/Library/", 16) == 0)  return NO;
    if (strncmp(path, "/System/", 8) == 0)           return NO;
    if (strncmp(path, "/Developer/", 11) == 0)       return NO;
    if (strstr(path, "/usr/lib/dyld"))               return NO;
    if (strstr(path, "libsystem_"))                  return NO;
    // 白名单（子串匹配，兼容 .app/Frameworks/xxx.framework/xxx 这种路径）
    if (strstr(path, "marki_cn"))      return YES;
    if (strstr(path, "GLCameraSDK"))   return YES;
    if (strstr(path, "GPUMarkSDK"))    return YES;
    return NO;
}

static int MKRebindOneImage(const struct mach_header_64 *hdr, intptr_t slide,
                            MKHookEntry *tab, int tabCount) {
    if (!hdr || hdr->magic != MH_MAGIC_64) return 0;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command     *symtab   = NULL;
    const struct dysymtab_command   *dysym    = NULL;
    const char *cursor = (const char *)hdr + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command)) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, SEG_LINKEDIT) == 0) linkedit = sg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysym = (const struct dysymtab_command *)lc;
        }
        cursor += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysym) return 0;
    intptr_t linkEditBase = (intptr_t)(linkedit->vmaddr - linkedit->fileoff) + slide;
    const struct nlist_64 *syms = (const struct nlist_64 *)(linkEditBase + symtab->symoff);
    const char *strtab = (const char *)(linkEditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkEditBase + dysym->indirectsymoff);

    if (!tab || tabCount <= 0) return 0;
    int patched = 0;
    cursor = (const char *)hdr + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command)) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            BOOL pacSegment = (strncmp(sg->segname, "__AUTH", 6) == 0);
            const char *sectAddr = (const char *)sg + sizeof(struct segment_command_64);
            for (uint32_t si = 0; si < sg->nsects; si++) {
                const struct section_64 *sec = (const struct section_64 *)(sectAddr + si * sizeof(struct section_64));
                BOOL isGot  = (strcmp(sec->sectname, "__got") == 0) || (strcmp(sec->sectname, "__nl_symbol_ptr") == 0);
                BOOL isLazy = (strcmp(sec->sectname, "__la_symbol_ptr") == 0);
                if (!isGot && !isLazy) continue;
                if (pacSegment) continue;
                if (sec->offset == 0 || sec->size == 0) continue;
                uint32_t count = (uint32_t)(sec->size / sizeof(void *));
                uint32_t base  = sec->reserved1;
                void **slots = (void **)((char *)hdr + sec->offset);
                for (uint32_t k = 0; k < count; k++) {
                    uint32_t idx = indirect[base + k];
                    if (idx == INDIRECT_SYMBOL_LOCAL || idx == INDIRECT_SYMBOL_ABS) continue;
                    const char *nm = strtab + syms[idx].n_un.n_strx;
                    for (int t = 0; t < tabCount; t++) {
                        if (strcmp(nm, tab[t].name) != 0) continue;
                        if (slots[k] == tab[t].rep) break;               // 已改过
                        if (gRebindCount >= MK_MAX_REBINDS) break;
                        if (*(tab[t].origSlot) == NULL) continue;        // 真身未知 → 不动
                        if (!MKMakeWritable(&slots[k], sizeof(void *))) break;
                        gRebinds[gRebindCount].slot  = &slots[k];
                        gRebinds[gRebindCount].orig  = slots[k];
                        gRebinds[gRebindCount].group = tab[t].group;
                        gRebindCount++;
                        slots[k] = tab[t].rep;
                        patched++;
                        break;
                    }
                }
            }
        }
        cursor += lc->cmdsize;
    }
    return patched;
}

// 通用：在所有白名单镜像里改写 tab 里列出的符号
static int MKRebindAllImages(MKHookEntry *tab, int tabCount, const char *tag) {
    int total = 0, scanned = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!MKImageAllowed(path)) continue;          // 系统库一律跳过
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        int got = MKRebindOneImage((const struct mach_header_64 *)h, slide, tab, tabCount);
        if (got) MKLog(@"%s：%s → 改写 %d 个槽位", tag ? tag : "rebind", path, got);
        scanned++;
        total += got;
    }
    MKLog(@"%s fishhook: 共 %u 个镜像，白名单命中 %d 个，改写 %d 个槽位",
          tag ? tag : "rebind", n, scanned, total);
    return total;
}

static BOOL MKApplyClockHook(void) {
    if (gClockHooked) return YES;
    if (!gOrigTime || !gOrigGettimeofday || !gOrigClockGettime) {
        gOrigTime          = (time_t (*)(time_t *))dlsym(RTLD_DEFAULT, "time");
        gOrigGettimeofday  = (int (*)(struct timeval *, void *))dlsym(RTLD_DEFAULT, "gettimeofday");
        gOrigClockGettime  = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_DEFAULT, "clock_gettime");
    }
    if (!gOrigTime || !gOrigGettimeofday || !gOrigClockGettime) {
        MKLog(@"✗ 时钟 fishhook：dlsym 拿不到真身，放弃（绝不用 stub 地址当原函数）");
        return NO;
    }
    MKHookEntry tab[3] = {
        { "_time",          (void *)MK_time,          (void **)&gOrigTime,          MK_GROUP_CLOCK },
        { "_gettimeofday",  (void *)MK_gettimeofday,  (void **)&gOrigGettimeofday,  MK_GROUP_CLOCK },
        { "_clock_gettime", (void *)MK_clock_gettime, (void **)&gOrigClockGettime,  MK_GROUP_CLOCK },
    };
    int total = MKRebindAllImages(tab, 3, "时钟");
    gClockHooked = (total > 0);
    return gClockHooked;
}

// 只还原指定 group 的记录，其余保留
static void MKRevertGroup(int group) {
    int kept = 0, reverted = 0;
    for (int i = 0; i < gRebindCount; i++) {
        if (gRebinds[i].group == group) {
            MKMakeWritable(gRebinds[i].slot, sizeof(void *));
            *(gRebinds[i].slot) = gRebinds[i].orig;
            reverted++;
        } else {
            gRebinds[kept++] = gRebinds[i];
        }
    }
    gRebindCount = kept;
    MKLog(@"fishhook 已还原 group=%d 共 %d 个槽位（剩余 %d）", group, reverted, gRebindCount);
}

static void MKRevertClockHook(void) {
    MKRevertGroup(MK_GROUP_CLOCK);
    gClockHooked = NO;
    gClockActive = NO;
}

static void MKRecomputeTimeDelta(void) {
    MKFakeCfg *c = CFG();
    NSDate *fake = MKParseFakeTime(c.fakeTime);
    if (!fake) { gTimeDelta = 0; gClockActive = NO; return; }
    time_t real = gOrigTime ? gOrigTime(NULL) : (time_t)[[NSDate date] timeIntervalSince1970];
    gTimeDelta = (int)llround([fake timeIntervalSince1970] - (double)real);
    gClockActive = (c.timeOn && c.safeClockOn && gClockHooked);
    MKLog(@"时钟 delta=%d 秒 (%.1f 天) active=%d (timeOn=%d safeClock=%d hooked=%d)",
          gTimeDelta, (double)gTimeDelta / 86400.0, (int)gClockActive,
          (int)c.timeOn, (int)c.safeClockOn, (int)gClockHooked);
}

static void MKSetSafeClock(BOOL on) {
    MKFakeCfg *c = CFG();
    c.safeClockOn = on;
    if (on) {
        BOOL ok = MKApplyClockHook();
        if (!ok) {
            MKAlert(@"时钟 Hook 失败", @"当前设备未命中 __got 槽位（arm64e 认证指针）。\n定位/相册/时间格式化仍可用，只有水印底层时间不会变。");
        }
    } else {
        MKRevertClockHook();
    }
    [c save];
    MKRecomputeTimeDelta();
}

static IMP o_stringFromDate = NULL, o_dateNow = NULL, o_dateNowClass = NULL;
static NSDate *gFakeDate = nil;
static NSArray<NSString *> *MKTimeFormats(void) {
    static NSArray *a = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[@"yyyy-MM-dd HH:mm", @"yyyy-MM-dd HH:mm:ss", @"yyyy年MM月dd日", @"yyyy/MM/dd HH:mm", @"yyyy/MM/dd HH:mm:ss", @"yyyy-MM-dd", @"HH:mm", @"HH:mm:ss", @"MM-dd HH:mm", @"yyyyMMdd HHmmss"]; });
    return a;
}
static NSDate *MKParseFakeTime(NSString *s) {
    if (s.length < 16) return nil;
    int Y = 0, M = 0, D = 0, h = 0, m = 0, sec = 0;
    if (sscanf(s.UTF8String, "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &sec) < 5) return nil;
    NSDateComponents *c = [NSDateComponents new]; c.year = Y; c.month = M; c.day = D; c.hour = h; c.minute = m; c.second = sec;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"] ?: [NSTimeZone localTimeZone];
    return [cal dateFromComponents:c];
}
static void MKRefreshFakeDate(void) {
    gFakeDate = MKParseFakeTime(CFG().fakeTime);
    MKLog(@"假时间 \"%@\" → NSDate=%@", CFG().fakeTime, gFakeDate);
    MKRecomputeTimeDelta();
}
static id h_stringFromDate(id self, SEL _cmd, NSDate *date) {
    if (!CFG().timeOn || !gFakeDate) return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
    NSString *fmt = nil; @try { fmt = [(NSDateFormatter *)self dateFormat]; } @catch (NSException *e) { fmt = nil; }
    if (!fmt || [MKTimeFormats() containsObject:fmt]) return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, gFakeDate);
    return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
}
static id h_dateNow(id self, SEL _cmd) { if (CFG().timeOn && gFakeDate) return gFakeDate; return ((id (*)(id, SEL))o_dateNow)(self, _cmd); }
static id h_dateDate(id self, SEL _cmd) {
    id real = ((id (*)(id, SEL))o_dateNowClass)(self, _cmd);
    if (!CFG().timeOn || gTimeDelta == 0) return real;
    return [real dateByAddingTimeInterval:(NSTimeInterval)gTimeDelta];
}
static void MKInstallTimeHooks(void) {
    MKRefreshFakeDate();
    o_stringFromDate = MKHook(objc_getClass("NSDateFormatter"), @selector(stringFromDate:), (IMP)h_stringFromDate, "Time_Formatter");
    o_dateNow = MKHookClass(objc_getClass("NSDate"), @selector(now), (IMP)h_dateNow, "Time_Now");
    o_dateNowClass = MKHookClass(objc_getClass("NSDate"), @selector(date), (IMP)h_dateDate, "Time_Date");
}

static IMP o_setCondTxt = NULL, o_setTemperature = NULL, o_getCondTxt = NULL, o_getTemperature = NULL;
static void h_setCondTxt(id self, SEL _cmd, NSString *v) { if (CFG().wxOn) v = CFG().wxText; ((void (*)(id, SEL, id))o_setCondTxt)(self, _cmd, v); }
static void h_setTemperature(id self, SEL _cmd, long long v) { if (CFG().wxOn) v = CFG().wxTemp; ((void (*)(id, SEL, long long))o_setTemperature)(self, _cmd, v); }
static id h_getCondTxt(id self, SEL _cmd) { if (CFG().wxOn) return CFG().wxText; return ((id (*)(id, SEL))o_getCondTxt)(self, _cmd); }
static long long h_getTemperature(id self, SEL _cmd) { if (CFG().wxOn) return CFG().wxTemp; return ((long long (*)(id, SEL))o_getTemperature)(self, _cmd); }

static IMP o_gmUpdateItem = NULL, o_gmGetContent = NULL;
static BOOL MKLooksLikeWeather(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length == 0 || s.length > 24) return NO;
    if ([s containsString:@"℃"] || [s containsString:@"°"]) return YES;
    NSArray *kw = @[@"晴", @"多云", @"阴", @"小雨", @"中雨", @"大雨", @"暴雨", @"阵雨", @"雷阵雨", @"雪", @"雾", @"霾", @"沙尘", @"大风", @"微风", @"空气质量"];
    for (NSString *k in kw) if ([s containsString:k]) return YES;
    return NO;
}
static NSString *MKFakeWeatherText(NSString *orig) {
    MKFakeCfg *c = CFG(); if (!c.wxText.length) return orig;
    if ([orig containsString:@"°"] || [orig containsString:@"℃"]) return [NSString stringWithFormat:@"%@ %lld°", c.wxText, c.wxTemp];
    return c.wxText;
}
static void h_gmUpdateItem(id self, SEL _cmd, int itemId, id content) {
    if (CFG().wxOn && MKLooksLikeWeather(content)) content = MKFakeWeatherText(content);
    ((void (*)(id, SEL, int, id))o_gmUpdateItem)(self, _cmd, itemId, content);
}
static id h_gmGetContent(id self, SEL _cmd, int itemId) {
    id r = ((id (*)(id, SEL, int))o_gmGetContent)(self, _cmd, itemId);
    if (MKLooksLikeWeather(r)) { if (CFG().wxOn) return MKFakeWeatherText(r); }
    return r;
}
static void MKInstallWeatherHooks(void) {
    o_gmUpdateItem = MKHook(objc_getClass("GMWatermarkItemCallback"), MKSEL(updateItemWithId:withContent:), (IMP)h_gmUpdateItem, "Wx_Engine1");
    o_gmGetContent = MKHook(objc_getClass("GPUMarkImageFilter"), MKSEL(getWatermarkItemContentWithId:), (IMP)h_gmGetContent, "Wx_Engine2");
    Class w = objc_getClass("MKWeatherInfo");
    if (!w) return;
    o_setCondTxt = MKHook(w, MKSEL(setCondTxt:), (IMP)h_setCondTxt, "Wx_SetTxt");
    o_setTemperature = MKHook(w, MKSEL(setTemperature:), (IMP)h_setTemperature, "Wx_SetTemp");
    Method mc = class_getInstanceMethod(w, MKSEL(condTxt)); if (mc && MKRetType(mc) == '@') o_getCondTxt = MKHook(w, MKSEL(condTxt), (IMP)h_getCondTxt, "Wx_GetTxt");
    Method mt = class_getInstanceMethod(w, MKSEL(temperature)); if (mt && (MKRetType(mt) == 'q' || MKRetType(mt) == 'Q')) o_getTemperature = MKHook(w, MKSEL(temperature), (IMP)h_getTemperature, "Wx_GetTemp");
}
// =============================================================================
//  MARK: - 验真对齐（地址 + EXIF）
//
//  问题一：水印地址 vs 验真报告地址不一致
//    marki 的反查链路（静态确认）：
//      LocationAdjustManager -requestLocationOnceWithClosure:
//      LocationAdjustManager -locationManualUpdateWithNotification:
//        两条都 classref 了 MKLocationReGeocode，把反查结果塞进这个模型，
//        水印和验真报告都从这里读。
//    CLGeocoder 本身在 marki_cn 里**没有 classref**，说明它走的是高德/百度 SDK
//    自带的反查（AMapLocationReGeocode）。所以：
//      ① 主 Hook：MKLocationReGeocode 的 getter 全量改写 → 两条链路同时对齐
//      ② 辅助：AMapLocationReGeocode / CLGeocoder 也一起改，防止有分支绕过模型
//
//  问题二：验真报告"缺少验真信息"
//    没有找到名为 verifyPhoto / checkVerify 的本地布尔判定；
//    checkUploadImageExifInfoIsValid 只是一个日志串，唯一引用在
//     HEPhotoPickerViewController（相册筛选"这张是不是马克拍的"）。
//    真正的判据是照片里的元数据 + 盲水印，所以从这两处下手：
//      ① CGImageSourceCopyPropertiesAtIndex → 给"没有 ImageDescription 的图"补元数据
//      ② GMBlindWatermark extractHashWithImage: → 学一次真图的哈希再复用
// =============================================================================

// 地址拆解：把 CFG().addr 拆成 省/市/区/街道 四段，喂给各家模型
static NSArray<NSString *> *MKAddrParts(void) {
    NSString *a = CFG().addr ?: @"";
    NSString *prov = @"", *city = @"", *dist = @"", *street = a;
    NSArray *provKeys = @[@"省", @"自治区", @"特别行政区"];
    NSArray *cityKeys = @[@"市", @"自治州", @"地区"];
    NSArray *distKeys = @[@"区", @"县", @"市辖区", @"旗"];

    NSUInteger loc = 0;
    for (NSString *k in provKeys) {
        NSRange r = [a rangeOfString:k];
        if (r.location != NSNotFound && r.location < 12) {
            prov = [a substringToIndex:NSMaxRange(r)];
            loc = NSMaxRange(r);
            break;
        }
    }
    if (loc < a.length) {
        NSString *rest = [a substringFromIndex:loc];
        for (NSString *k in cityKeys) {
            NSRange r = [rest rangeOfString:k];
            if (r.location != NSNotFound && r.location < 12) {
                city = [rest substringToIndex:NSMaxRange(r)];
                loc += NSMaxRange(r);
                break;
            }
        }
    }
    if (loc < a.length) {
        NSString *rest = [a substringFromIndex:loc];
        for (NSString *k in distKeys) {
            NSRange r = [rest rangeOfString:k];
            if (r.location != NSNotFound && r.location < 14) {
                dist = [rest substringToIndex:NSMaxRange(r)];
                loc += NSMaxRange(r);
                break;
            }
        }
    }
    if (loc < a.length) street = [a substringFromIndex:loc];
    if (!street.length) street = a;
    return @[prov ?: @"", city ?: @"", dist ?: @"", street ?: @""];
}

// ---- ① 反查模型全字段强制 ----
// 坑：四个类（marki / 高德 / 百度 / 腾讯）字段名一样，如果共用一个 static 原实现槽位，
// 第二个类会把第一个类的 IMP 当成自己的 orig，关掉开关时就是错误 ABI 调用 → 崩溃。
// 所以按 (Class, SEL) 逐个存原实现。
#define MK_PY_MAX 64
typedef struct { Class cls; SEL sel; IMP orig; } MKPySlot;
static MKPySlot gPySlots[MK_PY_MAX];
static int      gPyCount = 0;

static IMP MKRegeoOrig(id obj, SEL sel) {
    Class k = object_getClass(obj);
    while (k) {
        for (int i = 0; i < gPyCount; i++) {
            if (gPySlots[i].cls == k && sel_isEqual(gPySlots[i].sel, sel)) return gPySlots[i].orig;
        }
        k = class_getSuperclass(k);
    }
    return NULL;
}
#define MK_RG_GETTER(fn, expr) \
    static id fn(id s_, SEL c) { \
        if (CFG().locOn) return (expr); \
        IMP o = MKRegeoOrig(s_, c); \
        return o ? ((id (*)(id, SEL))o)(s_, c) : nil; \
    }

MK_RG_GETTER(mk_rgName,      CFG().addr)
MK_RG_GETTER(mk_rgCountry,   @"中国")
MK_RG_GETTER(mk_rgProv,      MKAddrParts()[0])
MK_RG_GETTER(mk_rgCity,      MKAddrParts()[1])
MK_RG_GETTER(mk_rgDistrict,  MKAddrParts()[2])
MK_RG_GETTER(mk_rgTown,      MKAddrParts()[2])
MK_RG_GETTER(mk_rgStreet,    MKAddrParts()[3])
MK_RG_GETTER(mk_rgStreetNum, @"")
MK_RG_GETTER(mk_rgPoiName,   CFG().addr)

static BOOL mk_rgValid(id s_, SEL c) {
    if (CFG().locOn) return YES;
    IMP o = MKRegeoOrig(s_, c);
    return o ? ((BOOL (*)(id, SEL))o)(s_, c) : NO;
}

static void MKForceRegeocodeClass(const char *clsName, const char *tag) {
    Class cls = objc_getClass(clsName);
    if (!cls) { MKLog(@"· 反查模型 %s 不存在，跳过", clsName); return; }

    int n = 0;
    struct { const char *sel; IMP fn; } t[] = {
        { "name",      (IMP)mk_rgName },
        { "country",   (IMP)mk_rgCountry },
        { "province",  (IMP)mk_rgProv },
        { "city",      (IMP)mk_rgCity },
        { "district",  (IMP)mk_rgDistrict },
        { "town",      (IMP)mk_rgTown },
        { "street",    (IMP)mk_rgStreet },
        { "streetNum", (IMP)mk_rgStreetNum },
        { "poiName",   (IMP)mk_rgPoiName },
    };

    for (int i = 0; i < 9; i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:t[i].sel]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || MKRetType(m) != '@') continue;
        IMP old = method_getImplementation(m);
        if (old == t[i].fn) continue;
        if (gPyCount < MK_PY_MAX) {
            gPySlots[gPyCount].cls  = cls;
            gPySlots[gPyCount].sel  = sel;
            gPySlots[gPyCount].orig = old;
            gPyCount++;
        }
        method_setImplementation(m, t[i].fn);
        n++;
    }

    SEL vSel = NSSelectorFromString(@"isValid");
    Method vm = class_getInstanceMethod(cls, vSel);
    if (vm && MKRetType(vm) == 'B') {
        IMP old = method_getImplementation(vm);
        if (old != (IMP)mk_rgValid) {
            if (gPyCount < MK_PY_MAX) {
                gPySlots[gPyCount].cls = cls; gPySlots[gPyCount].sel = vSel; gPySlots[gPyCount].orig = old;
                gPyCount++;
            }
            method_setImplementation(vm, (IMP)mk_rgValid);
            n++;
        }
    }
    MKLog(@"✓ 反查模型 %s 强制 %d 个字段（%s）", clsName, n, tag);
}

// ---- ② CLGeocoder 兜底：命中我们的坐标就不查真图 ----
static IMP o_reverseGeo = NULL;

static void mk_reverseGeo(id self, SEL _cmd, CLLocation *loc, id handler) {
    if (CFG().locOn && loc && handler) {
        CLLocationCoordinate2D c = loc.coordinate;
        double dLat = fabs(c.latitude  - CFG().lat);
        double dLng = fabs(c.longitude - CFG().lng);
        // 0.01 度 ≈ 1.1km，足够覆盖"我们伪造的那个点"
        if (dLat < 0.01 && dLng < 0.01) {
            NSArray *p = MKAddrParts();
            NSDictionary *addrDict = @{
                @"Name"                : CFG().addr ?: @"",
                @"Country"             : @"中国",
                @"CountryCode"         : @"CN",
                @"State"               : p[0],
                @"City"                : p[1],
                @"SubAdministrativeArea": p[2],
                @"SubLocality"         : p[2],
                @"Thoroughfare"        : p[3],
                @"Street"              : p[3],
                @"FormattedAddressLines": @[CFG().addr ?: @""],
            };
            MKPlacemark *mp = [[MKPlacemark alloc] initWithCoordinate:c addressDictionary:addrDict];
            CLPlacemark *cp = [[CLPlacemark alloc] initWithPlacemark:mp];
            MKLog(@"CLGeocoder 拦截 (%.6f,%.6f) → %@", c.latitude, c.longitude, CFG().addr);
                        void (^h)(NSArray *, NSError *) = (void (^)(NSArray *, NSError *))handler;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (h) h(cp ? @[cp] : @[], nil);
            });
            return;
        }
    }
    ((void (*)(id, SEL, id, id))o_reverseGeo)(self, _cmd, loc, handler);
}

// ---- ③ EXIF 注入：给"没有 ImageDescription 的图"补元数据 ----
static BOOL gVerifyExifOn = NO;
static CFDictionaryRef (*gOrigCGISProps)(CGImageSourceRef, size_t, CFDictionaryRef) = NULL;

static CFDictionaryRef mk_CGImageSourceCopyPropertiesAtIndex(CGImageSourceRef src, size_t idx,
                                                             CFDictionaryRef opts) {
    CFDictionaryRef orig = gOrigCGISProps ? gOrigCGISProps(src, idx, opts) : NULL;
    if (!orig || !gVerifyExifOn) return orig;

    NSDictionary *d = (__bridge NSDictionary *)orig;

    // 已经是"真马克照片"（自带 ImageDescription）→ 顺便把真实取值打出来，方便抄
    NSDictionary *tiff0 = d[(id)kCGImagePropertyTIFFDictionary];
    NSString *existDesc = tiff0[(id)kCGImagePropertyTIFFImageDescription];
    if (existDesc.length) {
        if (CFG().verifyExifText.length == 0) {
            MKLOG_ONCE(@"★ 真图 ImageDescription = %@（可抄进 CFG.verifyExifText）", existDesc);
        }
        return orig;
    }

    // 缩略图不处理，避免相册滚动卡顿
    NSNumber *pw = d[(id)kCGImagePropertyPixelWidth];
    if (pw && pw.doubleValue < 800) return orig;

    NSMutableDictionary *mut = [d mutableCopy];
    NSString *txt = CFG().verifyExifText.length ? CFG().verifyExifText : @"Marki Camera";

    NSMutableDictionary *tiff = [mut[(id)kCGImagePropertyTIFFDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    tiff[(id)kCGImagePropertyTIFFImageDescription] = txt;
    tiff[(id)kCGImagePropertyTIFFMake] = @"Apple";
    tiff[(id)kCGImagePropertyTIFFModel] = (tiff[(id)kCGImagePropertyTIFFModel] ?: @"iPhone");
    mut[(id)kCGImagePropertyTIFFDictionary] = tiff;

    NSMutableDictionary *iptc = [mut[(id)kCGImagePropertyIPTCDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    iptc[(id)kCGImagePropertyIPTCCaptionAbstract] = txt;
    mut[(id)kCGImagePropertyIPTCDictionary] = iptc;

    NSMutableDictionary *exif = [mut[(id)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    exif[(id)kCGImagePropertyExifUserComment] = txt;
    mut[(id)kCGImagePropertyExifDictionary] = exif;

    MKLOG_ONCE(@"★ EXIF 注入生效：ImageDescription/Caption = %@", txt);
    return (CFDictionaryRef)CFRetain((__bridge CFTypeRef)mut);
}

// ---- ④ 盲水印：学一次真图哈希，之后一直复用 ----
static IMP o_bwExtract = NULL, o_bwDecode = NULL;
static id gBlindHash = nil;

static id mk_bwExtract(id self, SEL _cmd, id img) {
    id r = ((id (*)(id, SEL, id))o_bwExtract)(self, _cmd, img);
    if (r && ![r isKindOfClass:[NSNull class]]) {
        if (!gBlindHash || ![gBlindHash isEqual:r]) {
            gBlindHash = r;
            MKLog(@"盲水印哈希已学习 len=%lu", (unsigned long)[(NSData *)r length]);
        }
        return r;
    }
    if (gBlindHash) {
        MKLOG_ONCE(@"盲水印提取为空 → 复用已学习的哈希");
        return gBlindHash;
    }
    return r;
}

static id mk_bwDecode(id self, SEL _cmd, id img, id size) {
    id r = ((id (*)(id, SEL, id, id))o_bwDecode)(self, _cmd, img, size);
    if (!r) MKLOG_ONCE(@"盲水印解码为空（本地验真可能因此失败）");
    return r;
}

static void MKInstallVerifyHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    // ① 反查模型（主要修复点）
    MKForceRegeocodeClass("MKLocationReGeocode",   "marki");
    MKForceRegeocodeClass("AMapLocationReGeocode", "高德");
    MKForceRegeocodeClass("BMKLocationReGeocode",  "百度");
    MKForceRegeocodeClass("TencentLBSReGeocode",   "腾讯");

    // ② CLGeocoder 兜底
    o_reverseGeo = MKHook(objc_getClass("CLGeocoder"),
                          @selector(reverseGeocodeLocation:completionHandler:),
                          (IMP)mk_reverseGeo, "Verify_CLGeocoder");

    // ③ EXIF 注入（走 fishhook，改 marki_cn 的 __got 槽位）
    gVerifyExifOn = CFG().verifyOn;
    if (gVerifyExifOn) {
        if (!gOrigCGISProps) {
            gOrigCGISProps = (CFDictionaryRef (*)(CGImageSourceRef, size_t, CFDictionaryRef))
                             dlsym(RTLD_DEFAULT, "CGImageSourceCopyPropertiesAtIndex");
        }
        if (gOrigCGISProps) {
            MKHookEntry tab[1] = {
                { "_CGImageSourceCopyPropertiesAtIndex",
                  (void *)mk_CGImageSourceCopyPropertiesAtIndex,
                  (void **)&gOrigCGISProps, MK_GROUP_EXIF },
            };
            MKRebindAllImages(tab, 1, "EXIF");
        } else {
            MKLog(@"✗ 拿不到 CGImageSourceCopyPropertiesAtIndex 真身，EXIF 注入不可用");
        }
    }

    // ④ 盲水印
    Class bw = objc_getClass("GMBlindWatermark");
    if (bw) {
        o_bwExtract = MKHook(bw, NSSelectorFromString(@"extractHashWithImage:"),
                             (IMP)mk_bwExtract, "Verify_BlindExtract");
        o_bwDecode  = MKHook(bw, NSSelectorFromString(@"decodeWithImage:adnInnerSize:"),
                             (IMP)mk_bwDecode, "Verify_BlindDecode");
    } else {
        MKLog(@"· GMBlindWatermark 未加载，盲水印 hook 跳过");
    }
}

// =============================================================================
//  MARK: - UI 与业务逻辑
// =============================================================================

#define MKC_RGB(r,g,b)     [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]
#define MKC_RGBA(r,g,b,a)  [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)]
static UIColor *MKC_BG(void) { return MKC_RGBA(26, 26, 34, 0.95); }
static UIColor *MKC_BOX(void) { return MKC_RGBA(46, 46, 58, 0.92); }
static UIColor *MKC_TEXT(void) { return MKC_RGB(242, 242, 247); }
static UIColor *MKC_SUB(void) { return MKC_RGBA(235, 235, 245, 0.55); }
static UIColor *MKC_GREEN(void) { return MKC_RGB(48, 209, 88); }
static UIColor *MKC_ORANGE(void) { return MKC_RGB(255, 159, 10); }
static UIColor *MKC_RED(void) { return MKC_RGB(255, 69, 58); }
static UIColor *MKC_BLUE(void) { return MKC_RGB(10, 132, 255); }
static UIColor *MKC_PURPLE(void) { return MKC_RGB(191, 90, 242); }
static UIColor *MKC_TEAL(void) { return MKC_RGB(48, 176, 199); }

static UIWindow *gFABWindow = nil; static BOOL gPanelShown = NO;

// 用「弱引用 + UIKit 真实状态」代替布尔锁：面板被任何方式收掉（点背景、点 ✕、被系统
// 收起、present 失败）都不会把锁卡死。上一版 gPanelOnScreen 一旦停在 YES 就永远弹不出来。
// 这里故意声明成 UIViewController*：MKPanelViewController 在后面才定义，
// 提前 @class 的话编译器看不到 presentingViewController / isBeingDismissed。
static __weak UIViewController *gPanelVC = nil;
static BOOL gPanelPresenting = NO;

static BOOL MKPanelAlive(void) {
    UIViewController *vc = gPanelVC;
    if (!vc) return NO;
    if (vc.isBeingDismissed) return NO;
    return (vc.presentingViewController != nil);
}
static void MKPanelUnlock(void) { gPanelPresenting = NO; gPanelVC = nil; }

static UIViewController *MKTopVC(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) { if (w == gFABWindow) continue; if (w.isKeyWindow) { key = w; break; } }
            if (key) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!key) { for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w == gFABWindow) continue; if (w.isKeyWindow) { key = w; break; } } }
    if (!key) key = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
static NSString *MKLogWhole(void) { NSString *s = [NSString stringWithContentsOfFile:MKLogFilePath() encoding:NSUTF8StringEncoding error:NULL]; return s.length ? s : @"（暂无日志）"; }

static void MKSnack(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        if (@available(iOS 13.0, *)) { for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) { if (![sc isKindOfClass:[UIWindowScene class]]) continue; for (UIWindow *x in ((UIWindowScene *)sc).windows) { if (x == gFABWindow) continue; if (x.isKeyWindow) { w = x; break; } } if (w) break; } }
        if (!w) w = [UIApplication sharedApplication].keyWindow; if (!w) return;
        UILabel *l = [UILabel new]; l.text = text; l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0; l.backgroundColor = MKC_RGBA(0, 0, 0, 0.82); l.layer.cornerRadius = 12; l.layer.masksToBounds = YES;
        CGFloat maxW = w.bounds.size.width - 80; CGSize sz = [l sizeThatFits:CGSizeMake(maxW - 28, CGFLOAT_MAX)];
        l.frame = CGRectMake(0, 0, sz.width + 28, sz.height + 18); l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height - 110); l.alpha = 0; [w addSubview:l];
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL f) { [UIView animateWithDuration:0.25 delay:1.6 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL d) { [l removeFromSuperview]; }]; }];
    });
}
static void MKAlert(NSString *title, NSString *msg) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = MKTopVC(); if (!top) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

@interface MKFABWindow : UIWindow @end
@implementation MKFABWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { UIView *v = [super hitTest:point withEvent:event]; if (v == self || v == self.rootViewController.view) return nil; return v; }
@end

static void MKShowPanel(void);
@interface MKFABTarget : NSObject @end
@implementation MKFABTarget
- (void)mkTap:(id)sender { MKShowPanel(); }
- (void)mkPan:(UIPanGestureRecognizer *)g { UIView *v = g.view; CGPoint p = [g translationInView:v.superview]; v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y); [g setTranslation:CGPointZero inView:v.superview]; }
@end
static MKFABTarget *gFABTarget = nil;

static void MKInstallFAB(void) {
    if (!CFG().fab) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFABWindow) return;
        MKFABWindow *w = [[MKFABWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1; w.backgroundColor = [UIColor clearColor]; w.rootViewController = [UIViewController new];
        if (@available(iOS 13.0, *)) { for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) { if ([sc isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)sc; break; } } }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = CGRectMake(10, 150, 46, 46); b.backgroundColor = MKC_RGBA(0, 0, 0, 0.55); b.layer.cornerRadius = 23; b.layer.masksToBounds = YES; b.layer.borderWidth = 1; b.layer.borderColor = MKC_RGBA(255, 255, 255, 0.5).CGColor;
        [b setTitle:@"假" forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; b.titleLabel.font = [UIFont boldSystemFontOfSize:19];
        gFABTarget = [MKFABTarget new];
        [b addTarget:gFABTarget action:@selector(mkTap:) forControlEvents:UIControlEventTouchUpInside];
        [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gFABTarget action:@selector(mkPan:)]];
        [w.rootViewController.view addSubview:b]; w.hidden = NO; gFABWindow = w;
    });
}

@interface MKDatePickerSheet : UIViewController
@property (nonatomic, copy) void (^onDone)(NSDate *date);
@property (nonatomic, strong) NSDate *initialDate;
@end
@implementation MKDatePickerSheet
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MKC_RGBA(0, 0, 0, 0.45); self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height, sheetH = 320;
    UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, H - sheetH, W, sheetH)]; sheet.backgroundColor = MKC_RGB(38, 38, 46);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:sheet.bounds byRoundingCorners:(UIRectCornerTopLeft | UIRectCornerTopRight) cornerRadii:CGSizeMake(16, 16)];
    CAShapeLayer *mask = [CAShapeLayer layer]; mask.path = bp.CGPath; sheet.layer.mask = mask; [self.view addSubview:sheet];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, W, 22)]; t.text = @"选择拍摄时间"; t.textAlignment = NSTextAlignmentCenter; t.textColor = MKC_TEXT(); t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; [sheet addSubview:t];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem]; cancel.frame = CGRectMake(8, 6, 64, 30); [cancel setTitle:@"取消" forState:UIControlStateNormal]; [cancel addTarget:self action:@selector(cancelTap) forControlEvents:UIControlEventTouchUpInside]; [sheet addSubview:cancel];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem]; done.frame = CGRectMake(W - 72, 6, 64, 30); [done setTitle:@"确定" forState:UIControlStateNormal]; done.titleLabel.font = [UIFont boldSystemFontOfSize:16]; [done addTarget:self action:@selector(doneTap) forControlEvents:UIControlEventTouchUpInside]; [sheet addSubview:done];
    UIDatePicker *dp = [[UIDatePicker alloc] initWithFrame:CGRectMake(0, 42, W, 260)]; dp.datePickerMode = UIDatePickerModeDateAndTime; dp.preferredDatePickerStyle = UIDatePickerStyleWheels; dp.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"]; dp.overrideUserInterfaceStyle = UIUserInterfaceStyleDark; dp.date = self.initialDate ?: [NSDate date]; dp.tag = 9001; [sheet addSubview:dp];
}
- (void)cancelTap { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)doneTap { UIDatePicker *dp = (UIDatePicker *)[self.view viewWithTag:9001]; NSDate *d = dp ? dp.date : [NSDate date]; if (self.onDone) self.onDone(d); [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static NSString *MKFormatDateManual(NSDate *d) {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; cal.timeZone = [NSTimeZone localTimeZone];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) fromDate:d];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld:%02ld:%02ld", (long)c.year, (long)c.month, (long)c.day, (long)c.hour, (long)c.minute, (long)c.second];
}

static const double MK_PI = 3.1415926535897932384626, MK_AXIS = 6378245.0, MK_EE = 0.00669342162296594323;
static BOOL MKOutOfChina(double lat, double lng) { return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55); }
static double MKTransLat(double x, double y) {
    double r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * MK_PI) + 20.0 * sin(2.0 * x * MK_PI)) * 2.0 / 3.0; r += (20.0 * sin(y * MK_PI) + 40.0 * sin(y / 3.0 * MK_PI)) * 2.0 / 3.0;
    r += (160.0 * sin(y / 12.0 * MK_PI) + 320.0 * sin(y * MK_PI / 30.0)) * 2.0 / 3.0; return r;
}
static double MKTransLng(double x, double y) {
    double r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * MK_PI) + 20.0 * sin(2.0 * x * MK_PI)) * 2.0 / 3.0; r += (20.0 * sin(x * MK_PI) + 40.0 * sin(x / 3.0 * MK_PI)) * 2.0 / 3.0;
    r += (150.0 * sin(x / 12.0 * MK_PI) + 300.0 * sin(x / 30.0 * MK_PI)) * 2.0 / 3.0; return r;
}
static CLLocationCoordinate2D MKWGS84FromGCJ02(double lat, double lng) {
    if (MKOutOfChina(lat, lng)) return CLLocationCoordinate2DMake(lat, lng);
    double dLat = MKTransLat(lng - 105.0, lat - 35.0), dLng = MKTransLng(lng - 105.0, lat - 35.0);
    double radLat = lat / 180.0 * MK_PI, magic = sin(radLat); magic = 1 - MK_EE * magic * magic;
    double sq = sqrt(magic); dLat = (dLat * 180.0) / ((MK_AXIS * (1 - MK_EE)) / (magic * sq) * MK_PI);
    dLng = (dLng * 180.0) / (MK_AXIS / sq * cos(radLat) * MK_PI); return CLLocationCoordinate2DMake(lat - dLat, lng - dLng);
}

@interface MKMapPickerViewController : UIViewController <MKMapViewDelegate, CLLocationManagerDelegate>
@property (nonatomic, copy) void (^onPick)(double lat, double lng, NSString *addr);
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UILabel *coordLabel, *addrLabel;
@property (nonatomic, strong) UIButton *okButton;
@property (nonatomic, strong) CLLocationManager *locMgr;
@property (nonatomic, assign) BOOL laidOut, resolving;
@end
@implementation MKMapPickerViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor systemBackgroundColor]; self.modalPresentationStyle = UIModalPresentationFullScreen;
    _mapView = [[MKMapView alloc] initWithFrame:self.view.bounds]; _mapView.delegate = self; _mapView.showsCompass = YES; _mapView.showsScale = NO; [self.view addSubview:_mapView];
    MKFakeCfg *c = CFG(); CLLocationCoordinate2D center = CLLocationCoordinate2DMake(c.lat, c.lng);
    if (fabs(c.lat) < 1e-6 && fabs(c.lng) < 1e-6) center = CLLocationCoordinate2DMake(39.9042, 116.4074);
    [_mapView setRegion:MKCoordinateRegionMakeWithDistance(center, 1200, 1200) animated:NO];
    [self buildTopBar]; [self buildPin]; [self buildInfoBox];
}
- (void)buildTopBar {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)]; bar.backgroundColor = MKC_RGBA(255, 255, 255, 0.94); bar.tag = 7001; bar.autoresizingMask = UIViewAutoresizingFlexibleWidth; [self.view addSubview:bar];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 52, bar.bounds.size.width, 30)]; title.text = @"选择位置"; title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:17]; title.textColor = [UIColor blackColor]; title.autoresizingMask = UIViewAutoresizingFlexibleWidth; [bar addSubview:title];
    NSString *lefts[2] = {@"取消", @"搜索"}, *rights[2] = {@"定位自己", @"确定"};
    for (int i = 0; i < 2; i++) { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; b.frame = CGRectMake(i == 0 ? 14 : 74, 54, 56, 26); [b setTitle:lefts[i] forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:16]; b.tag = 7100 + i; [b addTarget:self action:@selector(topBarTap:) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:b]; }
    for (int i = 0; i < 2; i++) { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; CGFloat w = (i == 0) ? 72 : 48; b.frame = CGRectMake(bar.bounds.size.width - 14 - w - (i == 0 ? 58 : 0), 54, w, 26); [b setTitle:rights[i] forState:UIControlStateNormal]; b.titleLabel.font = (i == 1) ? [UIFont boldSystemFontOfSize:16] : [UIFont systemFontOfSize:16]; b.tag = 7110 + i; b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; [b addTarget:self action:@selector(topBarTap:) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:b]; if (i == 1) self.okButton = b; }
}
- (void)buildPin {
    UIImageView *pin = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)]; pin.tag = 7002; UIImage *img = [UIImage systemImageNamed:@"mappin.circle.fill"];
    if (img) { pin.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]; pin.tintColor = [UIColor systemRedColor]; } pin.contentMode = UIViewContentModeScaleAspectFit; [self.view addSubview:pin];
}
- (void)buildInfoBox {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(12, 0, self.view.bounds.size.width - 24, 64)]; box.tag = 7003; box.backgroundColor = MKC_RGBA(255, 255, 255, 0.93); box.layer.cornerRadius = 12; box.layer.masksToBounds = YES; box.autoresizingMask = UIViewAutoresizingFlexibleWidth; [self.view addSubview:box];
    _coordLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, box.bounds.size.width - 24, 20)]; _coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium]; _coordLabel.textColor = [UIColor blackColor]; _coordLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth; _coordLabel.text = @"地图 GCJ-02 --"; [box addSubview:_coordLabel];
    _addrLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, box.bounds.size.width - 24, 20)]; _addrLabel.font = [UIFont systemFontOfSize:12]; _addrLabel.textColor = MKC_RGB(110, 110, 115); _addrLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth; _addrLabel.text = @"保存 WGS-84 --"; [box addSubview:_addrLabel];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; if (self.laidOut) return; self.laidOut = YES;
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    UIView *bar = [self.view viewWithTag:7001], *pin = [self.view viewWithTag:7002], *box = [self.view viewWithTag:7003];
    CGFloat barH = 96; bar.frame = CGRectMake(0, 0, W, barH); self.mapView.frame = CGRectMake(0, barH, W, H - barH);
    if (pin) pin.center = CGPointMake(W / 2, (H + barH) / 2 - 20); if (box) box.frame = CGRectMake(12, H - 96, W - 24, 64);
    [self updateCoordLabels];
}
- (void)mapViewDidChangeVisibleRegion:(MKMapView *)mapView { [self updateCoordLabels]; }
- (void)updateCoordLabels {
    CLLocationCoordinate2D gcj = self.mapView.centerCoordinate, wgs = MKWGS84FromGCJ02(gcj.latitude, gcj.longitude);
    _coordLabel.text = [NSString stringWithFormat:@"地图 GCJ-02 %.6f, %.6f", gcj.latitude, gcj.longitude]; _addrLabel.text = [NSString stringWithFormat:@"保存 WGS-84 %.6f, %.6f", wgs.latitude, wgs.longitude];
}
- (void)topBarTap:(UIButton *)b {
    if (b.tag == 7100) { [self dismissViewControllerAnimated:YES completion:nil]; return; } if (b.tag == 7101) { [self doSearch]; return; }
    if (b.tag == 7110) { [self doLocateSelf]; return; } if (b.tag == 7111) { [self doConfirm]; return; }
}
- (void)doSearch {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"搜索位置" message:@"输入地点、道路、小区或公司名称" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"例如：北京西站"; tf.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { NSString *q = ac.textFields.firstObject.text; if (!q.length) return; [self runSearch:q]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)runSearch:(NSString *)q {
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init]; req.naturalLanguageQuery = q; req.region = self.mapView.region;
    MKLocalSearch *s = [[MKLocalSearch alloc] initWithRequest:req];
    [s startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *err) {
        if (err || resp.mapItems.count == 0) { MKAlert(@"没找到", @"换个关键词试试，或检查网络。"); return; }
        MKMapItem *it = resp.mapItems.firstObject; CLLocationCoordinate2D c = it.placemark.coordinate; [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 600, 600) animated:YES];
    }];
}
- (void)doLocateSelf {
    if (!_locMgr) { _locMgr = [CLLocationManager new]; _locMgr.delegate = self; _locMgr.desiredAccuracy = kCLLocationAccuracyHundredMeters; }
    if (_locMgr.authorizationStatus == kCLAuthorizationStatusNotDetermined) [_locMgr requestWhenInUseAuthorization];
    [_locMgr startUpdatingLocation];
}
- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)locs {
    if (!locs.count) return; CLLocation *l = locs.lastObject; [m stopUpdatingLocation]; [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(l.coordinate, 800, 800) animated:YES];
}
- (void)doConfirm {
    if (self.resolving) return; self.resolving = YES; self.okButton.enabled = NO; [self.okButton setTitle:@"反查中…" forState:UIControlStateNormal];
    CLLocationCoordinate2D gcj = self.mapView.centerCoordinate, wgs = MKWGS84FromGCJ02(gcj.latitude, gcj.longitude);
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:gcj.latitude longitude:gcj.longitude]; CLGeocoder *geo = [CLGeocoder new]; __block BOOL finished = NO;
    void (^finish)(NSString *) = ^(NSString *addr) {
        if (finished) return; finished = YES; NSString *finalAddr = addr.length ? addr : [NSString stringWithFormat:@"%.6f,%.6f", wgs.latitude, wgs.longitude];
        MKFakeCfg *c = CFG(); c.lat = wgs.latitude; c.lng = wgs.longitude; c.addr = finalAddr; c.locOn = YES; [c save];
        if (self.onPick) self.onPick(c.lat, c.lng, c.addr); [self dismissViewControllerAnimated:YES completion:nil];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(nil); });
    [geo reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *pm, NSError *err) {
        if (err || !pm.count) { finish(nil); return; } CLPlacemark *p = pm.firstObject; NSMutableArray *parts = [NSMutableArray array];
        if (p.administrativeArea.length) [parts addObject:p.administrativeArea]; if (p.locality.length && ![p.locality isEqualToString:p.administrativeArea]) [parts addObject:p.locality];
        if (p.subLocality.length) [parts addObject:p.subLocality]; if (p.thoroughfare.length) [parts addObject:p.thoroughfare];
        if (p.subThoroughfare.length) [parts addObject:p.subThoroughfare]; if (p.name.length && ![[parts componentsJoinedByString:@""] containsString:p.name]) [parts addObject:p.name];
        finish([parts componentsJoinedByString:@""]);
    }];
}
@end

@interface MKLogViewController : UIViewController @end
@implementation MKLogViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MKC_RGB(20, 20, 26);
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)]; bar.backgroundColor = MKC_RGBA(38, 38, 46, 0.98); [self.view addSubview:bar];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 54, bar.bounds.size.width, 26)]; t.text = @"运行日志"; t.textAlignment = NSTextAlignmentCenter; t.font = [UIFont boldSystemFontOfSize:16]; t.textColor = MKC_TEXT(); [bar addSubview:t];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; close.frame = CGRectMake(10, 52, 60, 30); [close setTitle:@"关闭" forState:UIControlStateNormal]; [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:close];
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem]; clear.frame = CGRectMake(bar.bounds.size.width - 70, 52, 60, 30); [clear setTitle:@"清空" forState:UIControlStateNormal]; [clear setTitleColor:MKC_RED() forState:UIControlStateNormal]; [clear addTarget:self action:@selector(clearTap) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:clear];
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 96, self.view.bounds.size.width, self.view.bounds.size.height - 96)]; tv.tag = 8002; tv.backgroundColor = MKC_RGB(20, 20, 26); tv.textColor = MKC_RGBA(140, 250, 180, 0.92); tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; tv.editable = NO; tv.text = MKLogWhole(); tv.textContainerInset = UIEdgeInsetsMake(10, 10, 24, 10); [self.view addSubview:tv];
    dispatch_async(dispatch_get_main_queue(), ^{ [tv scrollRangeToVisible:NSMakeRange(tv.text.length ? tv.text.length - 1 : 0, 1)]; });
}
- (void)closeTap { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearTap { [[NSFileManager defaultManager] removeItemAtPath:MKLogFilePath() error:NULL]; ((UITextView *)[self.view viewWithTag:8002]).text = @"（日志已清空）"; }
@end

@interface MKPanelViewController : UIViewController <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIView *card; @property (nonatomic, strong) UILabel *statusLabel, *coordLabel;
@property (nonatomic, strong) NSMutableArray<UISwitch *> *switches;
@end
@implementation MKPanelViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MKC_RGBA(0, 0, 0, 0.42); self.modalPresentationStyle = UIModalPresentationOverFullScreen; self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve; self.switches = [NSMutableArray array]; [self buildCard];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTap:)]];
}
- (void)backgroundTap:(UITapGestureRecognizer *)g { if (!CGRectContainsPoint(self.card.frame, [g locationInView:self.view])) [self closeTap]; }
- (void)buildCard {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height, cardW = W - 28, cw = cardW - 28, pad = 14;
    CGFloat y = pad, headerH = 44, statusH = 74, coordH = 20, rowH = 54, footH = 42;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, pad + headerH + 8 + statusH + 6 + coordH + 10 + rowH * 7 + 10 + footH + pad)];
    card.backgroundColor = MKC_BG(); card.layer.cornerRadius = 18; card.layer.masksToBounds = NO; card.layer.borderWidth = 0.6; card.layer.borderColor = MKC_RGBA(255, 255, 255, 0.10).CGColor; card.layer.shadowColor = [UIColor blackColor].CGColor; card.layer.shadowOpacity = 0.45; card.layer.shadowRadius = 24; card.layer.shadowOffset = CGSizeMake(0, 10); card.center = CGPointMake(W / 2, H / 2);
    [self.view addSubview:card]; self.card = card;
    
    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(pad, y + 8, 3, 22)]; accent.backgroundColor = MKC_BLUE(); accent.layer.cornerRadius = 1.5; [card addSubview:accent];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad + 10, y + 2, cw - 80, 22)]; title.text = @"MarkiFake 控制台"; title.font = [UIFont boldSystemFontOfSize:16.5]; title.textColor = MKC_TEXT(); [card addSubview:title];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(pad + 10, y + 24, cw - 80, 16)]; sub.text = @"像素级换图 · 定位 · 时间 · 天气"; sub.font = [UIFont systemFontOfSize:11]; sub.textColor = MKC_SUB(); [card addSubview:sub];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom]; close.frame = CGRectMake(cardW - pad - 28, y + 8, 28, 28); close.backgroundColor = MKC_RGBA(255, 255, 255, 0.08); close.layer.cornerRadius = 14;
    UILabel *x = [[UILabel alloc] initWithFrame:close.bounds]; x.text = @"✕"; x.textAlignment = NSTextAlignmentCenter; x.textColor = MKC_TEXT(); x.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; x.userInteractionEnabled = NO; [close addSubview:x]; [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside]; [card addSubview:close];
    y += headerH + 8;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, statusH)]; box.backgroundColor = MKC_BOX(); box.layer.cornerRadius = 10; [card addSubview:box];
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, 9, cw - 24, 56)]; st.numberOfLines = 0; st.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]; st.textColor = MKC_RGBA(235, 235, 245, 0.85); [box addSubview:st]; self.statusLabel = st;
    y += statusH + 6;

    UILabel *coord = [[UILabel alloc] initWithFrame:CGRectMake(pad + 2, y, cw - 4, coordH)]; coord.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightRegular]; coord.textColor = MKC_SUB(); coord.lineBreakMode = NSLineBreakByTruncatingMiddle; [card addSubview:coord]; self.coordLabel = coord;
    y += coordH + 10;

    NSArray<NSString *> *rowTitles  = @[@"假定位", @"假时间", @"改天气", @"相册替拍", @"底层时钟", @"去广告", @"反作弊归零"];
    NSArray<NSString *> *btnTitles  = @[@"地图选点", @"设置时间", @"选择天气", @"选择图片", @"安装", @"启用", @"全部关闭"];
    NSArray<UIColor *>  *accents    = @[MKC_GREEN(), MKC_ORANGE(), MKC_RED(), MKC_TEAL(), MKC_BLUE(), MKC_PURPLE(), MKC_ORANGE()];
    NSArray<UIColor *>  *btnColors  = @[MKC_BLUE(), MKC_ORANGE(), MKC_ORANGE(), MKC_BLUE(), MKC_BLUE(), MKC_PURPLE(), MKC_RED()];
    for (NSInteger i = 0; i < rowTitles.count; i++) { [self addRowAtY:y index:i title:rowTitles[i] accent:accents[i] btnTitle:btnTitles[i] btnColor:btnColors[i] contentW:cw pad:pad]; y += rowH; }
    y += 10;

    UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeSystem]; logBtn.frame = CGRectMake(pad, y, cw, footH); logBtn.backgroundColor = MKC_RGBA(255, 255, 255, 0.07); logBtn.layer.cornerRadius = 10; [logBtn setTitle:@"查看运行日志" forState:UIControlStateNormal]; [logBtn setTitleColor:MKC_TEXT() forState:UIControlStateNormal]; logBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; [logBtn addTarget:self action:@selector(logTap) forControlEvents:UIControlEventTouchUpInside]; [card addSubview:logBtn];

    [self refreshStatus];
}
- (void)addRowAtY:(CGFloat)y index:(NSInteger)idx title:(NSString *)title accent:(UIColor *)accent btnTitle:(NSString *)btnTitle btnColor:(UIColor *)btnColor contentW:(CGFloat)cw pad:(CGFloat)pad {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 54)]; [self.card addSubview:row];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 16, 3, 22)]; bar.backgroundColor = accent; bar.layer.cornerRadius = 1.5; [row addSubview:bar];
    CGFloat btnW = 86, btnX = cw - btnW, swW = 51, swH = 31, swX = btnX - 10 - swW;
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, swX - 12, 54)]; lab.text = title; lab.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium]; lab.textColor = MKC_TEXT(); [row addSubview:lab];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(swX, (54 - swH) / 2, swW, swH)]; sw.tag = 7300 + idx; sw.onTintColor = accent; sw.transform = CGAffineTransformMakeScale(0.86, 0.86); [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged]; [row addSubview:sw]; [self.switches addObject:sw];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom]; btn.frame = CGRectMake(btnX, (54 - 32) / 2, btnW, 32); btn.backgroundColor = btnColor; btn.layer.cornerRadius = 9; [btn setTitle:btnTitle forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; btn.titleLabel.font = [UIFont boldSystemFontOfSize:12]; btn.tag = 7400 + idx; [btn addTarget:self action:@selector(actionTap:) forControlEvents:UIControlEventTouchUpInside]; [row addSubview:btn];
}
- (void)refreshStatus {
    MKFakeCfg *c = CFG();
    [self.switches[0] setOn:c.locOn animated:NO]; [self.switches[1] setOn:c.timeOn animated:NO]; [self.switches[2] setOn:c.wxOn animated:NO]; [self.switches[3] setOn:c.photoOn animated:NO]; [self.switches[4] setOn:c.safeClockOn animated:NO]; [self.switches[5] setOn:c.adBlockOn animated:NO]; [self.switches[6] setOn:c.antiOn animated:NO];
    NSString *(^Y)(BOOL) = ^NSString *(BOOL on) { return on ? @"开" : @"关"; };
    self.statusLabel.text = [NSString stringWithFormat:@"定位：%@  时间：%@  替拍：%@\n天气：%@  反作弊：%@\n时钟：%@  广告：%@", Y(c.locOn), Y(c.timeOn), Y(c.photoOn), Y(c.wxOn), Y(c.antiOn), c.safeClockOn ? (gClockHooked ? @"已装" : @"失败") : @"关", c.adBlockOn ? (gAdBlockActive ? @"拦" : @"待注册") : @"关"];
    NSString *img = c.imgPath.length ? c.imgPath : @"@latest"; if (img.length > 28) img = [img substringFromIndex:img.length - 28];
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f  ·  %@", c.lat, c.lng, img];
}
- (void)switchChanged:(UISwitch *)sw {
    MKFakeCfg *c = CFG(); NSInteger idx = sw.tag - 7300; BOOL on = sw.on;
    switch (idx) {
        case 0: c.locOn = on; gFakeLoc = nil; gFakeLat = -9999; gFakeLng = -9999; break;
        case 1: c.timeOn = on; MKRefreshFakeDate(); break;
        case 2: c.wxOn = on; break;
        case 3: c.photoOn = on; if (on) { c.photoAlways = NO; c.photoUntil = MKUnixNow() + 600; MKPrefetchSwapImage(); } break;
        case 4: @try { MKSetSafeClock(on); } @catch (NSException *e) {} break;
        case 5: c.adBlockOn = on; if (on) { MKInstallDeferredHooks(); MKInstallAdBlock(); if (!gAdBlockActive) MKAlert(@"去广告未生效", @"注册失败，可能是网络栈已固化 protocolClasses。重启 App 后自动重试。"); } else { MKAlert(@"去广告已关闭", @"已注册的 Protocol 无法反注册，重启 App 后彻底停用。"); } break;
        case 6: c.antiOn = on; break;
    }
    [c save]; [self refreshStatus]; MKSnack([NSString stringWithFormat:@"%@ 已%@", @[@"定位", @"时间", @"天气", @"相册替拍", @"底层时钟", @"去广告", @"反作弊"][MIN(idx, 6)], on ? @"开启" : @"关闭"]);
}
- (void)actionTap:(UIButton *)b {
    NSInteger idx = b.tag - 7400; MKFakeCfg *c = CFG();
    if (idx == 0) {
        MKMapPickerViewController *vc = [MKMapPickerViewController new]; __weak typeof(self) weakSelf = self;
        vc.onPick = ^(double lat, double lng, NSString *addr) { [weakSelf refreshStatus]; MKSnack(@"定位已更新"); };
        vc.modalPresentationStyle = UIModalPresentationFullScreen; [self presentViewController:vc animated:YES completion:nil]; return;
    }
    if (idx == 1) {
        MKDatePickerSheet *vc = [MKDatePickerSheet new]; NSDateComponents *cc = [NSDateComponents new];
        NSArray *p = [c.fakeTime componentsSeparatedByString:@" "], *d = [p.firstObject componentsSeparatedByString:@"-"], *t = [p.lastObject componentsSeparatedByString:@":"];
        if (d.count == 3 && t.count >= 2) { cc.year = [d[0] integerValue]; cc.month = [d[1] integerValue]; cc.day = [d[2] integerValue]; cc.hour = [t[0] integerValue]; cc.minute = [t[1] integerValue]; cc.second = t.count > 2 ? [t[2] integerValue] : 0; vc.initialDate = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] dateFromComponents:cc]; }
        __weak typeof(self) weakSelf = self;
        vc.onDone = ^(NSDate *date) { c.fakeTime = MKFormatDateManual(date); c.timeOn = YES; [c save]; MKRefreshFakeDate(); [weakSelf refreshStatus]; MKSnack([NSString stringWithFormat:@"假时间 %@", c.fakeTime]); };
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen; vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve; [self presentViewController:vc animated:YES completion:nil]; return;
    }
    if (idx == 2) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"修改天气" message:@"格式：天气,温度   例：多云,18" preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = [NSString stringWithFormat:@"%@,%lld", c.wxText, c.wxTemp]; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSArray *arr = [ac.textFields.firstObject.text componentsSeparatedByString:@","];
            if (arr.count >= 1 && [arr[0] length]) c.wxText = arr[0]; if (arr.count >= 2) c.wxTemp = [arr[1] integerValue];
            c.wxOn = YES; [c save]; [weakSelf refreshStatus]; MKSnack([NSString stringWithFormat:@"天气 %@ %lld°", c.wxText, c.wxTemp]);
        }]]; [self presentViewController:ac animated:YES completion:nil]; return;
    }
    if (idx == 3) {
        PHPickerConfiguration *conf = [[PHPickerConfiguration alloc] init]; conf.filter = [PHPickerFilter imagesFilter]; conf.selectionLimit = 1; conf.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:conf]; pk.delegate = self;
        [self presentViewController:pk animated:YES completion:nil]; return;
    }
    if (idx == 4) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"全部关闭" message:@"所有篡改暂停，hook 保留并直通原实现" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确认关闭" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            c.locOn = NO; c.timeOn = NO; c.wxOn = NO; c.photoOn = NO; c.photoAlways = NO; c.photoUntil = 0; c.antiOn = NO; [c save]; MKRefreshFakeDate(); [weakSelf refreshStatus]; MKSnack(@"已全部关闭");
        }]]; [self presentViewController:ac animated:YES completion:nil]; return;
    }
}
- (void)logTap { MKLogViewController *vc = [MKLogViewController new]; vc.modalPresentationStyle = UIModalPresentationFullScreen; [self presentViewController:vc animated:YES completion:nil]; }
- (void)closeTap {
    MKLog(@"面板关闭");
    gPanelPresenting = NO;
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:^{ MKPanelUnlock(); }];
    } else {
        MKPanelUnlock();          // 根本没挂上，直接解锁
    }
}

// 任何路径的消失都会走这里（包括被系统/其他 VC 收掉），兜底解锁
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.isBeingPresented && self.presentingViewController == nil) MKPanelUnlock();
}

// 把相册选图代理方法放在主类的 @end 里面（已修复分类报错）
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    PHPickerResult *r = results.firstObject; NSItemProvider *prov = r.itemProvider; __weak typeof(self) weakSelf = self;
    void (^saveImage)(UIImage *) = ^(UIImage *img) {
        if (!img) { MKAlert(@"读图失败", @"这张图读不出来，换一张试试"); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; NSString *path = [doc stringByAppendingPathComponent:@"swap_custom.jpg"];
            NSData *jpeg = UIImageJPEGRepresentation(img, 0.92); BOOL ok = jpeg.length && [jpeg writeToFile:path atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) { MKAlert(@"保存失败", path); return; }
                MKFakeCfg *c = CFG(); c.imgPath = path; c.photoOn = YES; c.photoAlways = NO; c.photoUntil = MKUnixNow() + 600; [c save]; MKPrefetchSwapImage(); [weakSelf refreshStatus]; MKSnack([NSString stringWithFormat:@"换图已设定 %.0f×%.0f", img.size.width, img.size.height]);
            });
        });
    };
    if ([prov canLoadObjectOfClass:[UIImage class]]) { [prov loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) { saveImage((UIImage *)obj); }]; return; }
    NSString *uti = prov.registeredTypeIdentifiers.firstObject; if (!uti) return;
    [prov loadFileRepresentationForTypeIdentifier:uti completionHandler:^(NSURL *url, NSError *err) { NSData *data = [NSData dataWithContentsOfURL:url]; saveImage(data.length ? [UIImage imageWithData:data] : nil); }];
}
@end

static void MKShowPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // ① 真的已经在屏幕上 → 什么都不做（不是靠布尔锁猜）
        if (MKPanelAlive()) { MKLog(@"面板已在屏幕上，忽略重复弹出"); return; }
        // ② 正在 present 的瞬间重复点击 → 忽略
        if (gPanelPresenting) { MKLog(@"面板正在 present，忽略"); return; }

        // ③ 走到这里说明锁是残留的（上次没走 closeTap），先清掉再继续
        MKPanelUnlock();

        UIViewController *top = MKTopVC();
        if (!top) { MKLog(@"没有顶层 VC，无法弹面板"); return; }
        if (top.presentedViewController) {
            MKLog(@"已有其它弹窗在显示：%@", NSStringFromClass([top.presentedViewController class]));
            return;
        }

        MKPanelViewController *vc = [MKPanelViewController new];
        gPanelVC = vc;
        gPanelPresenting = YES;

        [top presentViewController:vc animated:YES completion:^{
            gPanelPresenting = NO;
            BOOL ok = (vc.presentingViewController != nil);
            MKLog(@"面板 present 完成 alive=%d", ok);
            if (!ok) MKPanelUnlock();      // present 失败立刻解锁
        }];

        // ④ 兜底看门狗：completion 因为动画被打断而没跑时，也要解锁
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gPanelPresenting = NO;
            if (!MKPanelAlive()) {
                MKLog(@"面板未挂上，看门狗解锁");
                MKPanelUnlock();
            }
        });
    });
}

@interface MKAdBlockProtocol : NSURLProtocol @end
@implementation MKAdBlockProtocol
+ (NSArray<NSString *> *)mk_adKeywords {
    static NSArray *a = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[@"pangolin", @"snssdk", @"bytedance", @"pangle", @"byteimg.com/ad", @"gdt.qq.com", @"e.qq.com", @"adsmind", @"adnet.qq", @"kuaishou", @"gifshow", @"kwai", @"cpro", @"mobads", @"baidu.com/ad", @"union.baidu", @"jd.com/ad", @"tanx.com", @"alimama", @"umeng.com/ad", @"/api/ad", @"/ad/get", @"/adx", @"/splash/ad", @"/api/v1/ad"]; });
    return a;
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    if ([NSURLProtocol propertyForKey:@"MKAdBlocked" inRequest:request]) return NO;
    if (!gAdBlockActive) return NO;
    NSString *s = request.URL.absoluteString.lowercaseString; if (!s.length) return NO;
    for (NSString *k in [self mk_adKeywords]) { if ([s containsString:k]) return YES; }
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }
- (void)startLoading { NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:@{ NSLocalizedDescriptionKey : @"blocked by MarkiFake" }]; [self.client URLProtocol:self didFailWithError:err]; }
- (void)stopLoading { }
@end

static IMP o_setProtocolClasses = NULL;
static void h_setProtocolClasses(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *arr = [NSMutableArray arrayWithObject:[MKAdBlockProtocol class]];
    for (id c in classes) if (c != [MKAdBlockProtocol class]) [arr addObject:c];
    ((void (*)(id, SEL, id))o_setProtocolClasses)(self, _cmd, arr);
}

// ============================================================================
//  NSURLSession 层兜底拦截
//  NSURLProtocol 只能拦「默认配置 + 走 protocolClasses 链路」的请求，很多大厂 SDK
//  直接用自己的 session / CFNetwork，所以再在 dataTask 入口换 URL：
//  换成一个必定 connection refused 的地址（127.0.0.1:1），立刻拿到
//  NSURLErrorCannotConnectToHost(-1004)，不产生任何流量，也不会 hang。
//  换 URL 而不是返回 nil/dummy task，调用方拿到的是正常的 task 对象，不会崩。
// ============================================================================

static NSURL *MKBlockedURL(void) {
    static NSURL *u = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ u = [NSURL URLWithString:@"http://127.0.0.1:1/__mk_adblocked__"]; });
    return u;
}

static BOOL MKIsAdURL(NSURL *url) {
    if (!url || !gAdBlockActive) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    if (!s.length) return NO;
    if ([s containsString:@"__mk_adblocked__"]) return NO;   // 自己造的地址，别再拦
    for (NSString *k in [MKAdBlockProtocol mk_adKeywords]) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static NSURLRequest *MKNeutralize(NSURLRequest *req) {
    if (![req isKindOfClass:[NSURLRequest class]]) return req;
    if (!MKIsAdURL(req.URL)) return req;
    NSMutableURLRequest *m = [req mutableCopy];
    m.URL = MKBlockedURL();
    MKLog(@"广告请求换向: %@%@", req.URL.host, req.URL.path);
    return m;
}

static IMP o_dtReqCb = NULL, o_dtReq = NULL, o_dtUrlCb = NULL, o_dtUrl = NULL, o_syncReq = NULL;

static id h_dtReqCb(id self, SEL _cmd, NSURLRequest *req, id cb) {
    return ((id (*)(id, SEL, id, id))o_dtReqCb)(self, _cmd, MKNeutralize(req), cb);
}
static id h_dtReq(id self, SEL _cmd, NSURLRequest *req) {
    return ((id (*)(id, SEL, id))o_dtReq)(self, _cmd, MKNeutralize(req));
}
static id h_dtUrlCb(id self, SEL _cmd, NSURL *url, id cb) {
    return ((id (*)(id, SEL, id, id))o_dtUrlCb)(self, _cmd, MKIsAdURL(url) ? MKBlockedURL() : url, cb);
}
static id h_dtUrl(id self, SEL _cmd, NSURL *url) {
    return ((id (*)(id, SEL, id))o_dtUrl)(self, _cmd, MKIsAdURL(url) ? MKBlockedURL() : url);
}

// 老 SDK 用的同步接口，直接返回 nil + error
static NSData *h_syncReq(id self, SEL _cmd, NSURLRequest *req, NSURLResponse **resp, NSError **err) {
    if (MKIsAdURL(req.URL)) {
        MKLog(@"广告同步请求已拦截: %@", req.URL.host);
        if (resp) *resp = nil;
        if (err)  *err = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorCancelled
                                         userInfo:@{ NSLocalizedDescriptionKey : @"blocked by MarkiFake" }];
        return nil;
    }
    return ((NSData *(*)(id, SEL, id, NSURLResponse **, NSError **))o_syncReq)(self, _cmd, req, resp, err);
}

static void MKInstallAdBlock(void) {
    static BOOL done = NO; if (done) return;
    if (!CFG().adBlockOn) return;

    // ① 原来的 NSURLProtocol（保留）
    [NSURLProtocol registerClass:[MKAdBlockProtocol class]];
    gAdBlockActive = YES;
    done = YES;

    // ② 强制把拦截器插到 protocolClasses 第 0 位（压过 SDK 自己设的）
    o_setProtocolClasses = MKHook(objc_getClass("NSURLSessionConfiguration"), MKSEL(setProtocolClasses:), (IMP)h_setProtocolClasses, "AdBlock_SetProtocols");

    // ③ NSURLSession dataTask 入口
    Class sess = objc_getClass("NSURLSession");
    o_dtReqCb = MKHook(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)h_dtReqCb, "AdBlock_DataTaskReqCb");
    o_dtReq   = MKHook(sess, @selector(dataTaskWithRequest:),                    (IMP)h_dtReq,   "AdBlock_DataTaskReq");
    o_dtUrlCb = MKHook(sess, @selector(dataTaskWithURL:completionHandler:),      (IMP)h_dtUrlCb, "AdBlock_DataTaskUrlCb");
    o_dtUrl   = MKHook(sess, @selector(dataTaskWithURL:),                        (IMP)h_dtUrl,   "AdBlock_DataTaskUrl");

    // ④ NSURLConnection 同步接口
    o_syncReq = MKHookClass(objc_getClass("NSURLConnection"),
                            @selector(sendSynchronousRequest:returningResponse:error:),
                            (IMP)h_syncReq, "+[NSURLConnection sendSynchronousRequest:...]");

    MKLog(@"去广告已装：Protocol + 4 个 dataTask 入口 + 同步请求，关键字 %lu 条",
          (unsigned long)[MKAdBlockProtocol mk_adKeywords].count);
}

static void MKSafeInstall(void (*fn)(void), const char *name) { @try { fn(); } @catch (NSException *e) { MKLog(@"✗ 安装器 %s 抛异常: %@", name, e.reason); } @catch (id other) {} }

static void MKInstallAllHooks(void) {
    MKLog(@"========== MarkiFake 启动 ==========");
    MKSafeInstall(MKInstallLocationHooks, "定位"); MKSafeInstall(MKInstallAntiCheatHooks, "反作弊");
    MKSafeInstall(MKInstallCameraHooks, "相机"); MKSafeInstall(MKInstallWeatherHooks, "天气");
}

static void MKInstallDeferredHooks(void) {
    static BOOL done = NO; if (done) return; done = YES;
    MKSafeInstall(MKInstallTimeHooks, "时间(ObjC)");
    if (CFG().adBlockOn) { MKSafeInstall(MKInstallAdBlock, "去广告"); }
    if (CFG().safeClockOn) { @try { MKSetSafeClock(YES); } @catch (NSException *e) {} }
}

static void MKSchedulePanel(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (o_vsInit == NULL) MKInstallCameraHooks();
        if (o_gmUpdateItem == NULL) MKInstallWeatherHooks();
        { static BOOL vDone = NO; if (!vDone) { vDone = YES; MKSafeInstall(MKInstallVerifyHooks, "验真对齐(前台)"); } }
        MKInstallDeferredHooks();
        // 每次进前台都补一次悬浮球（MKInstallFAB 内部用 gFABWindow 做幂等），
        // 万一第一次没拿到 windowScene 也不会永远没有球
        MKInstallFAB();
        if (gPanelShown) return; gPanelShown = YES;
        // 不再自动弹面板：面板只由用户点悬浮球触发
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MKInstallFAB();
            if (CFG().photoOn) MKPrefetchSwapImage();
            MKLog(@"悬浮球就绪，点它打开面板");
        });
    }];
}

__attribute__((constructor))
static void MKFakeInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (!([bid isEqualToString:@"com.ai.marki"] || [bid containsString:@"marki"])) return;
        MKInstallAllHooks(); MKSchedulePanel();
    }
}
