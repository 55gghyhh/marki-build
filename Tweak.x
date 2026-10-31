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
#include <zlib.h>          // gzip 解压：地理接口响应可能被压缩
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
@property (nonatomic, assign) BOOL      renderOnly;        // 只改渲染层：网络/定位/时间全部真实
@property (nonatomic, assign) NSInteger clockScope;       // 0=关 1=只GPUMarkSDK(安全,默认) 2=白名单全开
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
        _renderOnly = NO;
        _clockScope = 1;
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
    if ([d objectForKey:@"mk.renderOnly"]) self.renderOnly = [d boolForKey:@"mk.renderOnly"];
    if ([d objectForKey:@"mk.clockScope"]) self.clockScope = [d integerForKey:@"mk.clockScope"];
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
    [d setBool:self.renderOnly forKey:@"mk.renderOnly"];
    [d setInteger:self.clockScope forKey:@"mk.clockScope"];
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
// 判断某个 KVC key 能不能安全塞 NSString：
//   · 有属性元数据 → 只接受 NSString / NSMutableString（防止把 @"..." 写进对象槽，
//     比如 reGeocode，之后 App 拿它当模型调 name 立刻崩）
//   · 没元数据（Swift @objc / 动态属性）→ 只在当前值为 nil 或本身就是字符串时动手
static BOOL MKSafeStringKey(Class cls, id model, NSString *key) {
    objc_property_t prop = class_getProperty(cls, key.UTF8String);
    if (prop) {
        const char *attrs = property_getAttributes(prop);
        if (!attrs) return NO;
        return (strstr(attrs, "@\"NSString\"") != NULL ||
                strstr(attrs, "@\"NSMutableString\"") != NULL);
    }
    @try {
        id cur = [model valueForKey:key];
        if (cur == nil) return YES;
        return [cur isKindOfClass:[NSString class]];
    } @catch (NSException *e) { return NO; }
}

static void MKSpoofModel(id model) {
    if (!model || !CFG().locOn || CFG().renderOnly) return;
    Class cls = object_getClass(model);

    // 经纬度：写不进去就说明这不是定位模型，直接收手
    @try {
        [model setValue:@(CFG().lat) forKey:@"latitude"];
        [model setValue:@(CFG().lng) forKey:@"longitude"];
    } @catch (NSException *e) { return; }

    if (!CFG().addr.length) return;

    // 穷举地址字段。故意不含 reGeocode / locationReGeocodeInfo —— 那两个是对象，
    // 塞字符串会崩；它们的 getter 已经在上面的「验真对齐」段里被强制改写。
    NSArray *addrKeys = @[@"address", @"nowAllAddress", @"name", @"poiName",
                          @"formattedAddress", @"detailAddress", @"addressName",
                          @"fullAddress", @"locationName", @"locationAddress",
                          @"addressDetail", @"positionAddress"];

    NSMutableArray *applied = [NSMutableArray array];
    for (NSString *key in addrKeys) {
        if (!MKSafeStringKey(cls, model, key)) continue;
        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                        [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]);
        if (![model respondsToSelector:setter]) continue;
        @try {
            [model setValue:CFG().addr forKey:key];
            [applied addObject:key];
        } @catch (NSException *e) {}
    }

    if (applied.count) {
        MKLOG_ONCE(@"地址注入 %@ → %@", NSStringFromClass(cls), [applied componentsJoinedByString:@","]);
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
static double h_infoLat(id self, SEL _cmd) { return (CFG().locOn && !CFG().renderOnly) ? CFG().lat : ((double (*)(id, SEL))o_infoLat)(self, _cmd); }
static double h_infoLng(id self, SEL _cmd) { return (CFG().locOn && !CFG().renderOnly) ? CFG().lng : ((double (*)(id, SEL))o_infoLng)(self, _cmd); }
static double h_objLat(id self, SEL _cmd) { return (CFG().locOn && !CFG().renderOnly) ? CFG().lat : ((double (*)(id, SEL))o_objLat)(self, _cmd); }
static double h_objLng(id self, SEL _cmd) { return (CFG().locOn && !CFG().renderOnly) ? CFG().lng : ((double (*)(id, SEL))o_objLng)(self, _cmd); }
static id h_locMgrLocation(id self, SEL _cmd) { if (CFG().locOn && !CFG().renderOnly) { CLLocation *f = MKFakeLocation(); if (f) return f; } return ((id (*)(id, SEL))o_locMgrLocation)(self, _cmd); }
static CLLocationCoordinate2D h_locCoord(id self, SEL _cmd) { if (CFG().locOn && !CFG().renderOnly) return CLLocationCoordinate2DMake(CFG().lat, CFG().lng); return ((CLLocationCoordinate2D (*)(id, SEL))o_locCoord)(self, _cmd); }
static id h_locSource(id self, SEL _cmd) { if (CFG().antiOn && CFG().locOn) return nil; return ((id (*)(id, SEL))o_locSource)(self, _cmd); }
static void MKHookDoubleGetter(Class cls, SEL sel, IMP fn, IMP *slot, const char *label) {
    if (!cls) return; Method m = class_getInstanceMethod(cls, sel); if (!m) return; if (MKRetType(m) != 'd') return; *slot = MKHook(cls, sel, fn, label);
}

// 字符串 getter（地址兜底用）：返回类型必须是 '@'
static void MKHookStringGetter(Class cls, SEL sel, IMP fn, IMP *slot, const char *label) {
    if (!cls) { MKLog(@"- %s: class nil", label); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { MKLog(@"- %s: no method", label); return; }
    if (MKRetType(m) != '@') { MKLog(@"- %s: return type %c != @", label, MKRetType(m)); return; }
    *slot = MKHook(cls, sel, fn, label);
}

static IMP o_infoAddr = NULL, o_objAddr = NULL, o_objNowAddr = NULL;

static id h_infoAddr(id self, SEL _cmd) {
    if (CFG().locOn && CFG().addr.length) return CFG().addr;
    return o_infoAddr ? ((id (*)(id, SEL))o_infoAddr)(self, _cmd) : nil;
}
static id h_objAddr(id self, SEL _cmd) {
    if (CFG().locOn && CFG().addr.length) return CFG().addr;
    return o_objAddr ? ((id (*)(id, SEL))o_objAddr)(self, _cmd) : nil;
}
static id h_objNowAddr(id self, SEL _cmd) {
    if (CFG().locOn && CFG().addr.length) return CFG().addr;
    return o_objNowAddr ? ((id (*)(id, SEL))o_objNowAddr)(self, _cmd) : nil;
}

// 探针：把类的实例方法全打出来，确认这个 build 里到底叫什么
static void MKDumpClassMethods(Class cls, const char *tag) {
    if (!cls) { MKLog(@"DUMP %s: class nil", tag); return; }
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(cls, &cnt);
    MKLog(@"DUMP %s <%s> : %u methods", tag, class_getName(cls), cnt);
    for (unsigned int i = 0; i < cnt; i++) {
        MKLog(@"   -%s   %s", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
    }
    free(ms);

    Class sup = class_getSuperclass(cls);
    if (sup && sup != objc_getClass("NSObject")) {
        unsigned int sc = 0;
        Method *sm = class_copyMethodList(sup, &sc);
        MKLog(@"DUMP %s super <%s> : %u methods", tag, class_getName(sup), sc);
        for (unsigned int i = 0; i < sc && i < 40; i++) {
            MKLog(@"   -%s   %s", sel_getName(method_getName(sm[i])), method_getTypeEncoding(sm[i]));
        }
        free(sm);
    }
}
static void MKInstallLocationHooks(void) {
    Class mgr = objc_getClass("MKLocationManager");

    // 探针：先把这个类的方法全打出来（这个 build 里 getRecentLocation/setRecentLocation: 都没了）
    MKDumpClassMethods(mgr, "MKLocationManager");

    if (mgr) {
        o_mgrGetRecent = MKHook(mgr, MKSEL(getRecentLocation), (IMP)h_mgrGetRecent, "Location_Get");
        o_mgrSetRecent = MKHook(mgr, MKSEL(setRecentLocation:), (IMP)h_mgrSetRecent, "Location_Set");
        o_mgrCheckAuth = MKHook(mgr, MKSEL(checkLocationAuthorization), (IMP)h_mgrCheckAuth, "Location_Auth");
    }

    Class info = objc_getClass("MKLocationInfo");
    MKDumpClassMethods(info, "MKLocationInfo");
    MKHookDoubleGetter(info, MKSEL(latitude), (IMP)h_infoLat, &o_infoLat, "Loc_Info_Lat");
    MKHookDoubleGetter(info, MKSEL(longitude), (IMP)h_infoLng, &o_infoLng, "Loc_Info_Lng");
    MKHookStringGetter(info, MKSEL(address), (IMP)h_infoAddr, &o_infoAddr, "Loc_Info_Addr");

    Class obj = objc_getClass("_TtC8marki_cn16MKLocationObject");
    MKDumpClassMethods(obj, "MKLocationObject");
    MKHookDoubleGetter(obj, MKSEL(latitude), (IMP)h_objLat, &o_objLat, "Loc_Obj_Lat");
    MKHookDoubleGetter(obj, MKSEL(longitude), (IMP)h_objLng, &o_objLng, "Loc_Obj_Lng");
    MKHookStringGetter(obj, MKSEL(address), (IMP)h_objAddr, &o_objAddr, "Loc_Obj_Addr");
    MKHookStringGetter(obj, MKSEL(nowAllAddress), (IMP)h_objNowAddr, &o_objNowAddr, "Loc_Obj_NowAddr");
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
#define MK_MAX_PER_IMAGE 4          // 单个镜像最多改几个槽位，防止"一改改一片"

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

// ---- 作用域：0=关  1=只动 GPUMarkSDK（安全，推荐）  2=白名单全开（激进） ----
static int  gClockScope = 1;
// EXIF 专用：安装期间强制放行 marki_cn（不受 clockScope 限制）
static BOOL gBypassScope = NO;
// 当前正在处理的镜像是否允许改 __la_symbol_ptr
static BOOL gCurImageLazyOK = NO;
static BOOL gAllowLazyPtr = NO;        // 是否允许改 __la_symbol_ptr（默认禁止）

// 二次硬拒名单：这些块即使路径里含白名单关键字也一律跳过。
// Flutter / App.framework 带 AOT 快照，改写 GOT 后 JIT/AOT 校验会直接 abort；
// 广告 SDK 自己的心跳线程对时间极敏感，改了就是随机闪退。
static BOOL MKImageBlacklisted(const char *path) {
    static const char *bad[] = {
        "Flutter", "App.framework", "libapp.so", "vm_snapshot",
        "AnyThinkSDK", "GDTMobSDK", "CSJ", "pangle", "QuMengAdSDK", "Sigmob",
        "Smartdigimkt", "AliyunOSSiOS", "Tquic", "Agora", "TTSDK", "Sentry",
        "SkyMediaSDK", "ardancegame", "facedancegame", "vn_", "of_effect",
        "of_pose", "of_avatar", "opencv", "yoga", NULL
    };
    for (int i = 0; bad[i]; i++) {
        if (strstr(path, bad[i])) return YES;
    }
    return NO;
}

// ---- 模块白名单 ----
static BOOL MKImageAllowed(const char *path) {
    if (!path) return NO;

    // 硬拒绝：系统库、系统框架、共享缓存、开发者目录
    if (strncmp(path, "/usr/lib/", 9) == 0)          return NO;
    if (strncmp(path, "/System/Library/", 16) == 0)  return NO;
    if (strncmp(path, "/System/", 8) == 0)           return NO;
    if (strncmp(path, "/Developer/", 11) == 0)       return NO;
    if (strstr(path, "/usr/lib/dyld"))               return NO;
    if (strstr(path, "libsystem_"))                  return NO;

    // 二次拒绝
    if (MKImageBlacklisted(path)) return NO;

    // EXIF 专用旁路：CGImageSourceCopyPropertiesAtIndex 的槽位在 marki_cn 里，
    // 如果跟着 clockScope 走，scope=1 时 EXIF 注入会被一起杀掉（实测 0 命中）。
    // 只放行主二进制，其余仍按 scope 判定。
    if (gBypassScope && strstr(path, "marki_cn")) return YES;

    // scope 1：只碰水印渲染器。GLCameraSDK 有 60fps 渲染线程，marki_cn 里有全部广告 SDK，
    // 两边都不该被改 —— 这是上一版 56 个槽位之后 10 秒闪退的直接原因。
    if (gClockScope <= 1) {
        return (strstr(path, "GPUMarkSDK") != NULL);
    }

    // scope 2：白名单全开（仍然受黑名单限制）
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
    if (gRebindCount >= MK_MAX_REBINDS) return 0;      // 全局配额已满

    int patched = 0;
    cursor = (const char *)hdr + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command)) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;

            // ① 段级硬判定：只接受 __DATA / __DATA_CONST。
            //    __AUTH* 是指针认证区（写了必 PAC 失败）；__TEXT 只读；
            //    其它段（__LINKEDIT / __LLVM_COV）根本不存放指针。
            BOOL segAuth  = (strncmp(sg->segname, "__AUTH", 6) == 0);
            BOOL segData  = (strcmp(sg->segname, "__DATA") == 0);
            BOOL segDCon  = (strcmp(sg->segname, "__DATA_CONST") == 0);
            if (segAuth || (!segData && !segDCon)) { cursor += lc->cmdsize; continue; }

            // ② 段可写性校验：不可写且不是 __DATA_CONST 的，一律跳过
            if (!segDCon && !(sg->initprot & VM_PROT_WRITE)) { cursor += lc->cmdsize; continue; }

            const char *sectAddr = (const char *)sg + sizeof(struct segment_command_64);
            for (uint32_t si = 0; si < sg->nsects; si++) {
                const struct section_64 *sec = (const struct section_64 *)(sectAddr + si * sizeof(struct section_64));

                BOOL isGot  = (strcmp(sec->sectname, "__got") == 0) ||
                              (strcmp(sec->sectname, "__nl_symbol_ptr") == 0);
                BOOL isLazy = (strcmp(sec->sectname, "__la_symbol_ptr") == 0);

                // ③ __la_symbol_ptr 默认完全禁止：
                //    惰性绑定槽位在首次调用前指向 dyld_stub_binder 跳板，
                //    改写它等于欺骗 dyld 的绑定流程，是 10 秒后随机崩溃的头号来源。
                if (isLazy && !gCurImageLazyOK) continue;
                if (!isGot && !isLazy) continue;

                // ④ 范围校验：section 必须完整落在本段文件映射内
                if (sec->offset == 0 || sec->size == 0) continue;
                if (sec->addr < sg->vmaddr) continue;
                if (sec->addr + sec->size > sg->vmaddr + sg->vmsize) continue;
                if (sec->size % sizeof(void *) != 0) continue;

                uint32_t count = (uint32_t)(sec->size / sizeof(void *));
                uint32_t base  = sec->reserved1;
                void **slots = (void **)((char *)hdr + sec->offset);

                for (uint32_t k = 0; k < count; k++) {
                    if (patched >= MK_MAX_PER_IMAGE) break;          // ⑤ 每镜像上限
                    if (gRebindCount >= MK_MAX_REBINDS) break;

                    uint32_t idx = indirect[base + k];
                    if (idx == INDIRECT_SYMBOL_LOCAL || idx == INDIRECT_SYMBOL_ABS) continue;
                    if (idx >= symtab->nsyms) continue;
                    const char *nm = strtab + syms[idx].n_un.n_strx;
                    if (!nm || !nm[0]) continue;

                    for (int t = 0; t < tabCount; t++) {
                        if (strcmp(nm, tab[t].name) != 0) continue;
                        if (slots[k] == tab[t].rep) break;               // 已改过
                        if (*(tab[t].origSlot) == NULL) break;           // 真身未知 → 不动

                        // ⑥ 去重：同一地址只记一次
                        BOOL dup = NO;
                        for (int d = 0; d < gRebindCount; d++) {
                            if (gRebinds[d].slot == &slots[k]) { dup = YES; break; }
                        }
                        if (dup) break;

                        if (!MKMakeWritable(&slots[k], sizeof(void *))) break;

                        void *oldPtr = slots[k];
                        slots[k] = tab[t].rep;

                        // ⑦ 写后校验：读回不一致就立刻还原，绝不留半改状态
                        if (slots[k] != tab[t].rep) {
                            slots[k] = oldPtr;
                            MKLog(@"✗ 写后校验失败 %s（%s）→ 已还原", nm, sg->segname);
                            break;
                        }

                        gRebinds[gRebindCount].slot  = &slots[k];
                        gRebinds[gRebindCount].orig  = oldPtr;
                        gRebinds[gRebindCount].group = tab[t].group;
                        gRebindCount++;
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
//   lazyOK      : YES = 允许改 __la_symbol_ptr（EXIF 需要，时钟只有 GPUMarkSDK 需要）
//   bypassScope : YES = 无视 clockScope 强制放行 marki_cn（EXIF 专用）
static int MKRebindAllImages(MKHookEntry *tab, int tabCount, const char *tag,
                             BOOL lazyOK, BOOL bypassScope) {
    int total = 0, scanned = 0;
    uint32_t n = _dyld_image_count();

    BOOL oldBypass = gBypassScope;
    gBypassScope = bypassScope;

    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!MKImageAllowed(path)) continue;          // 系统库一律跳过
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        // 每镜像单独决定能否碰 __la_symbol_ptr：
        //   EXIF 那边一律允许；时钟那边 scope=2 全放开，scope=1 只放开 GPUMarkSDK
        //   （实测 GPUMarkSDK 的 _time 就在 __la_symbol_ptr，不放行等于没改）
        gCurImageLazyOK = lazyOK
                       || (gClockScope >= 2)
                       || (gClockScope == 1 && strstr(path, "GPUMarkSDK") != NULL);

        int got = MKRebindOneImage((const struct mach_header_64 *)h, slide, tab, tabCount);
        if (got) MKLog(@"%s: %s -> %d slots", tag ? tag : "rebind", path, got);
        scanned++;
        total += got;
    }

    gBypassScope = oldBypass;
    gCurImageLazyOK = NO;

    MKLog(@"%s fishhook: %u images, %d allowed, %d slots rewritten",
          tag ? tag : "rebind", n, scanned, total);
    if (total > 12) {
        MKLog(@"WARN: %d slots is a lot, consider clockScope=1 (GPUMarkSDK only)", total);
    }
    return total;
}

static BOOL MKApplyClockHook(void) {
    if (gClockHooked) return YES;

    // 每次安装前从配置刷新作用域
    gClockScope   = (int)CFG().clockScope;
    gAllowLazyPtr = (gClockScope >= 2);
    MKLog(@"CLOCK fishhook: scope=%d (1=GPUMarkSDK only, 2=all whitelisted) lazyInGPUMark=YES",
          gClockScope);

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
    int total = MKRebindAllImages(tab, 3, "CLOCK", NO, NO);
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
    gClockActive = (c.timeOn && c.safeClockOn && gClockHooked && !c.renderOnly);
    MKLog(@"时钟 delta=%d 秒 (%.1f 天) active=%d (timeOn=%d safeClock=%d hooked=%d)",
          gTimeDelta, (double)gTimeDelta / 86400.0, (int)gClockActive,
          (int)c.timeOn, (int)c.safeClockOn, (int)gClockHooked);
}

// ============================================================================
//  时钟门控：临时让 C 层 time()/gettimeofday() 返回真实时间
//
//  · 引用计数：Geo 和 WM 可能并发，一次 pop 不会误关别人的窗口
//  · 看门狗：task 走不到 didComplete（超时/取消）时 3 秒强制归位
//  · 恢复值由 cfg 重算，绝不会停在错误状态
// ============================================================================
static volatile int gClockGate = 0;

static void MKClockGatePush(const char *tag) {
    gClockGate++;
    gClockActive = NO;                 // MK_time 是纯算术，读 volatile 立即生效
    MKLog(@"[ClockGate] PUSH(%s) depth=%d active=0 (real time)", tag, gClockGate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gClockGate > 0) {
            MKLog(@"[ClockGate] watchdog fire, force reset depth=%d", gClockGate);
            gClockGate = 0;
            MKFakeCfg *c = CFG();
            gClockActive = (c.timeOn && c.safeClockOn && gClockHooked && !c.renderOnly);
            MKLog(@"[ClockGate] restored active=%d", (int)gClockActive);
        }
    });
}

static void MKClockGatePop(const char *tag) {
    if (gClockGate > 0) gClockGate--;
    if (gClockGate == 0) {
        MKFakeCfg *c = CFG();
        gClockActive = (c.timeOn && c.safeClockOn && gClockHooked && !c.renderOnly);
        MKLog(@"[ClockGate] POP(%s) depth=0 active=%d", tag, (int)gClockActive);
    } else {
        MKLog(@"[ClockGate] POP(%s) depth=%d", tag, gClockGate);
    }
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

// 安全模式：0=关 1=只 GPUMarkSDK（默认/推荐） 2=白名单全开
static void MKSetClockScope(int scope) {
    MKFakeCfg *c = CFG();
    if (scope < 0) scope = 0;
    if (scope > 2) scope = 2;

    // 先整体还原，再按新作用域重装，避免旧槽位残留
    MKRevertClockHook();

    c.clockScope = scope;
    c.safeClockOn = (scope > 0);
    gClockScope = scope;
    gAllowLazyPtr = (scope >= 2);

    if (scope == 0) {
        [c save];
        MKRecomputeTimeDelta();
        MKLog(@"底层时钟：已关闭");
        return;
    }

    BOOL ok = MKApplyClockHook();
    [c save];
    MKRecomputeTimeDelta();
    MKLog(@"底层时钟：scope=%d 安装%s", scope, ok ? "OK" : "FAIL(no slot)");
    if (!ok) {
        MKAlert(@"时钟 Hook 未命中",
                scope == 1
                  ? @"GPUMarkSDK 里没有可改写的 __got 槽位。可切到「全开」再试，但风险更高。"
                  : @"所有白名单镜像都没命中 __got。此设备/此版本可能不支持底层时钟。");
    }
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
    if (!CFG().timeOn || !gFakeDate || CFG().renderOnly)
        return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
    NSString *fmt = nil; @try { fmt = [(NSDateFormatter *)self dateFormat]; } @catch (NSException *e) { fmt = nil; }
    if (!fmt || [MKTimeFormats() containsObject:fmt]) return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, gFakeDate);
    return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
}
static id h_dateNow(id self, SEL _cmd) { if (CFG().timeOn && gFakeDate && !CFG().renderOnly) return gFakeDate; return ((id (*)(id, SEL))o_dateNow)(self, _cmd); }
static id h_dateDate(id self, SEL _cmd) {
    id real = ((id (*)(id, SEL))o_dateNowClass)(self, _cmd);
    if (!CFG().timeOn || gTimeDelta == 0 || CFG().renderOnly) return real;
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

// ============================================================================
//  渲染层水印文本替换（最终方案）
//
//  思路：网络层、定位、时钟全部放行真实的，让服务端完美验签；
//        只在 GPUMarkSDK 把字符串画进图之前，把文本换掉。
//
//  GPUMarkSDK 里文本有 5 个出入口（都在二进制里确认过）：
//    ① GMWatermarkItemCallback -updateItemWithId:withContent:          (宿主 push)
//    ② GPUMarkImageFilter    -getWatermarkItemContentWithId:          (引擎 pull, 同步)
//    ③ GMCoreRender          -getWatermarkItemContentWithId:          (引擎 pull, 同步)
//    ④ GMCVPixelBuffer       -getWatermarkItemContentWithId:withCompletion:  (引擎 pull, 异步)
//    ⑤ GPUMarkImageFilter    -renderMarkWithInputTexture:andSize:andData:
//  ①②③ 全部接管；④ 只旁听打日志（它的 block 签名未知，裹一层会崩）；
//  ⑤ 是最终提交点，文本此时已固化成纹理，改不了，跳过。
// ============================================================================

static IMP o_gmUpdateItem = NULL, o_gmGetContent = NULL;
static IMP o_gmGetContent2 = NULL, o_gmGetContentAsync = NULL;

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

// ---- 日期/时间正则（惰性建一次）----
static NSRegularExpression *gReDate = nil, *gReDateCN = nil, *gReTime = nil;
static void MKInitWatermarkRegex(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *e = nil;
        gReDate   = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})" options:0 error:&e];
        gReDateCN = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4})年(\\d{1,2})月(\\d{1,2})日" options:0 error:&e];
        gReTime   = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2}):(\\d{2})(:\\d{2})?" options:0 error:&e];
    });
}

static BOOL MKLooksLikeAddress(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length < 4 || s.length > 64) return NO;
    if (MKLooksLikeWeather(s)) return NO;
    NSArray *kw = @[@"省", @"市", @"区", @"县", @"路", @"街", @"道", @"巷", @"镇", @"村",
                    @"号", @"小区", @"大厦", @"广场", @"公园", @"基地", @"园区", @"酒店",
                    @"公寓", @"花园", @"写字楼", @"中心"];
    for (NSString *k in kw) if ([s containsString:k]) return s.length >= 8;
    return NO;
}

// 把 fakeTime 拆成 日期串 / 时间串
static void MKFakeDateParts(NSString **dateOut, NSString **timeOut) {
    NSString *ft = CFG().fakeTime ?: @"2026-01-01 12:00:00";
    NSArray *p = [ft componentsSeparatedByString:@" "];
    *dateOut = p.count > 0 ? p[0] : @"2026-01-01";
    *timeOut = p.count > 1 ? p[1] : @"12:00:00";
}

// 只替换串里的日期/时间片段，别的一个字不动
static NSString *MKReplaceDateTime(NSString *s) {
    MKInitWatermarkRegex();
    NSString *d = nil, *t = nil;
    MKFakeDateParts(&d, &t);

    NSArray *dParts = [d componentsSeparatedByString:@"-"];
    NSString *dSlash = d, *dCN = d;
    if (dParts.count == 3) {
        dSlash = [NSString stringWithFormat:@"%@/%@/%@", dParts[0], dParts[1], dParts[2]];
        dCN    = [NSString stringWithFormat:@"%@年%ld月%ld日",
                  dParts[0], (long)[dParts[1] integerValue], (long)[dParts[2] integerValue]];
    }

    NSMutableString *out = [s mutableCopy];

    // 日期（yyyy-MM-dd / yyyy/MM/dd）
    NSArray *ms = [gReDate matchesInString:out options:0 range:NSMakeRange(0, out.length)];
    for (NSInteger i = (NSInteger)ms.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = ms[i];
        NSString *seg = [out substringWithRange:m.range];
        NSString *repl = [seg containsString:@"/"] ? dSlash : d;
        [out replaceCharactersInRange:m.range withString:repl];
    }
    // 日期（yyyy年M月d日）
    ms = [gReDateCN matchesInString:out options:0 range:NSMakeRange(0, out.length)];
    for (NSInteger i = (NSInteger)ms.count - 1; i >= 0; i--) {
        [out replaceCharactersInRange:[ms[i] range] withString:dCN];
    }
    // 时间（H:mm / H:mm:ss）
    ms = [gReTime matchesInString:out options:0 range:NSMakeRange(0, out.length)];
    for (NSInteger i = (NSInteger)ms.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = ms[i];
        NSString *seg = [out substringWithRange:m.range];
        BOOL withSec = (seg.length >= 7);
        NSString *repl = withSec ? t : (t.length >= 5 ? [t substringToIndex:5] : t);
        [out replaceCharactersInRange:m.range withString:repl];
    }
    return out;
}

// 总入口：itemId 只用来打日志，判断全靠内容形态
static id MKRewriteWatermarkText(id content, int itemId, const char *src) {
    if (![content isKindOfClass:[NSString class]]) return content;
    NSString *s = (NSString *)content;
    if (!s.length) return content;

    MKFakeCfg *c = CFG();
    if (!c.timeOn && !c.locOn && !c.wxOn) return content;   // 三个开关全关，零开销直通
    NSString *out = s;
    NSString *why = nil;

    BOOL hasDate = NO;
    MKInitWatermarkRegex();
    if ([gReDate numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] ||
        [gReDateCN numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] ||
        [gReTime numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        hasDate = YES;
    }

    if (hasDate && c.timeOn) {
        out = MKReplaceDateTime(s);
        why = @"time";
    } else if (!hasDate && c.locOn && MKLooksLikeAddress(s)) {
        // 纯地址串（不含日期），整串换掉最干净
        out = c.addr.length ? c.addr : s;
        why = @"addr";
    } else if (c.wxOn && MKLooksLikeWeather(s)) {
        out = MKFakeWeatherText(s);
        why = @"weather";
    }

    if (why) {
        // 这个函数会被 renderMark 每帧调用，同样的替换只打一次，避免日志刷爆
        static NSMutableSet *seen = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%s|%d|%@|%@", src, itemId, s, out];
        @synchronized (seen) {
            if (![seen containsObject:key]) {
                [seen addObject:key];
                if (seen.count > 256) [seen removeAllObjects];
                MKLog(@"[Render-%s] item#%d  \"%@\"  ->  \"%@\"", src, itemId, s, out);
            }
        }
    } else if (s.length && s.length < 40) {
        MKLOG_ONCE(@"· 未命中替换的 item 示例：item#%d \"%@\"（看日志后可加白名单）", itemId, s);
    }
    return out;
}

// ① 宿主 push
static void h_gmUpdateItem(id self, SEL _cmd, int itemId, id content) {
    content = MKRewriteWatermarkText(content, itemId, "push");
    ((void (*)(id, SEL, int, id))o_gmUpdateItem)(self, _cmd, itemId, content);
}
// ② GPUMarkImageFilter pull
static id h_gmGetContent(id self, SEL _cmd, int itemId) {
    id r = ((id (*)(id, SEL, int))o_gmGetContent)(self, _cmd, itemId);
    return MKRewriteWatermarkText(r, itemId, "pull");
}
// ③ GMCoreRender pull
static id h_gmGetContent2(id self, SEL _cmd, int itemId) {
    id r = ((id (*)(id, SEL, int))o_gmGetContent2)(self, _cmd, itemId);
    return MKRewriteWatermarkText(r, itemId, "core");
}
// ④ GMCVPixelBuffer async pull
//
//  block 的形参个数不明，硬裹 (id) 会崩。这里先读 Block_layout 的
//  descriptor->signature（这是 libclosure 里稳定十年的 ABI），数一下参数个数：
//    "v24@?0@\"NSString\"8"   → '@' 出现 2 次 = @? + 1 个对象参数 → 可以安全裹成 void(^)(id)
//    其它情况一律透传，只打一次签名日志。
typedef struct { void *isa; volatile int32_t flags; int32_t reserved; void *invoke; void *descriptor; } MKBlockLayout;
typedef struct { unsigned long reserved; unsigned long size; void *copy; void *dispose; const char *signature; } MKBlockDesc;

static const char *MKBlockSignature(id blk) {
    if (!blk) return NULL;
    MKBlockLayout *l = (__bridge MKBlockLayout *)blk;
    if (!l->descriptor) return NULL;
    MKBlockDesc *d = (MKBlockDesc *)l->descriptor;
    return d->signature;
}

// 只数 '@'：block 自身占一个 @?，每多一个对象参数就多一个 '@'
static int MKBlockObjArgCount(const char *sig) {
    if (!sig) return -1;
    int n = 0;
    for (const char *p = sig; *p; p++) if (*p == '@') n++;
    return n - 1;
}

static void h_gmGetContentAsync(id self, SEL _cmd, int itemId, id completion) {
    const char *sig = MKBlockSignature(completion);
    int argc = MKBlockObjArgCount(sig);

    MKLOG_ONCE(@"[AsyncPull] item#%d sig=%s argc=%d", itemId, sig ? sig : "(null)", argc);

    if (o_gmGetContentAsync && argc == 1 && completion) {
        __block void (^orig)(id) = (void (^)(id))completion;
        void (^wrap)(id) = ^(id content) {
            id nc = MKRewriteWatermarkText(content, itemId, "async");
            if (orig) orig(nc);
        };
        ((void (*)(id, SEL, int, id))o_gmGetContentAsync)(self, _cmd, itemId, [wrap copy]);
        return;
    }
    if (o_gmGetContentAsync) {
        ((void (*)(id, SEL, int, id))o_gmGetContentAsync)(self, _cmd, itemId, completion);
    }
}

// ============================================================================
//  最终提交点（拍照瞬间真正用于绘图的文本快照）
//
//  push / pull 两条路都改对了，但照片仍然是真时间 —— 说明绘图用的不是这两条：
//    ⑥ -renderMarkWithInputTexture:andSize:andData:  (v44@0:8i16{CGSize=dd}20@36)
//       andData 是拍照那一刻一次性传进去的 itemId→content 字典，绕过 push/pull。
//    ⑦ -filterCacheDataWithData:                     (@24@0:8@16)
//       纹理/数据缓存里存的是旧的真值，下次渲染直接从缓存取，也绕过 push/pull。
//  这两处必须一起接管，否则预览是假时间、成片是真时间。
// ============================================================================

static IMP o_renderMarkData = NULL, o_filterCache = NULL;

// ---------------------------------------------------------------------------
//  渲染闸门：renderMark* 是 60fps 高频路径，绝不能每帧都递归 + 正则 + copy。
//  思路：只在「按下快门」之后的 2 秒窗口内做替换，预览帧一律原样透传。
//  窗口由 capturePhoto* 三个入口点亮；如果三个入口都没命中（老版本/换实现），
//  则退回「始终允许」，保证功能不会因为钩子缺失而静默失效。
// ---------------------------------------------------------------------------
static volatile CFAbsoluteTime gRenderArmedUntil = 0;
static volatile BOOL gRenderGateEverArmed = NO;

static void MKRenderArm(const char *why) {
    gRenderArmedUntil = CFAbsoluteTimeGetCurrent() + 2.0;
    if (!gRenderGateEverArmed) {
        gRenderGateEverArmed = YES;
        MKLog(@"[RenderGate] armed first time by %s", why);
    }
}

static BOOL MKRenderArmed(void) {
    if (!gRenderGateEverArmed) return YES;                 // 钩子没命中，别把功能关死
    return (CFAbsoluteTimeGetCurrent() < gRenderArmedUntil);
}

// 快门入口 ① GLPreviewView
static IMP o_previewCapture = NULL;
static void h_previewCapture(id self, SEL _cmd, id factor, id outer, id complete) {
    MKRenderArm("GLPreviewView.capturePhoto");
    if (o_previewCapture) ((void (*)(id, SEL, id, id, id))o_previewCapture)(self, _cmd, factor, outer, complete);
}
// 快门入口 ② GLVideoDevice
static IMP o_deviceCapture = NULL;
static void h_deviceCapture(id self, SEL _cmd, id complete) {
    MKRenderArm("GLVideoDevice.capturePhoto");
    if (o_deviceCapture) ((void (*)(id, SEL, id))o_deviceCapture)(self, _cmd, complete);
}
// 快门入口 ③ GLSingleCapture
static IMP o_singleCapture = NULL;
static id h_singleCapture(id self, SEL _cmd) {
    MKRenderArm("GLSingleCapture.capturePhoto");
    return o_singleCapture ? ((id (*)(id, SEL))o_singleCapture)(self, _cmd) : nil;
}

// 递归替换任意容器里的字符串（只换命中日期/地址/天气的，其余原样返回）
static id MKRewriteDeepText(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = nil;
        for (id k in [(NSDictionary *)obj allKeys]) {
            id v = [(NSDictionary *)obj objectForKey:k];
            id nv = [v isKindOfClass:[NSString class]]
                  ? MKRewriteWatermarkText(v, -1, "data")
                  : MKRewriteDeepText(v);
            if (nv != v) {
                if (!out) out = [obj mutableCopy];
                out[k] = nv;
            }
        }
        return out ?: obj;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = nil;
        NSArray *arr = (NSArray *)obj;
        for (NSUInteger i = 0; i < arr.count; i++) {
            id v = arr[i];
            id nv = [v isKindOfClass:[NSString class]]
                  ? MKRewriteWatermarkText(v, -1, "data")
                  : MKRewriteDeepText(v);
            if (nv != v) {
                if (!out) out = [arr mutableCopy];
                out[i] = nv;
            }
        }
        return out ?: obj;
    }
    return obj;
}

// 观测：不带 data 的重载，成片如果走这条，说明文本来自 filter 内部存储（靠 ⑦ 缓存 hook 兜）
static IMP o_renderMarkPlain = NULL;
static void h_renderMarkPlain(id self, SEL _cmd, int tex, CGSize size) {
    MKLOG_ONCE(@"[Render-plain] renderMarkWithInputTexture:andSize: 被调用（成片可能走这条）");
    if (o_renderMarkPlain) ((void (*)(id, SEL, int, CGSize))o_renderMarkPlain)(self, _cmd, tex, size);
}

// ⑥ 最终提交（带闸门）
static void h_renderMarkData(id self, SEL _cmd, int tex, CGSize size, id data) {
    id nd = MKRenderArmed() ? MKRewriteDeepText(data) : data;
    ((void (*)(id, SEL, int, CGSize, id))o_renderMarkData)(self, _cmd, tex, size, nd);
}

// ⑦ 缓存（只在窗口内改写，避免把预览期的真值也永久污染成假值）
static id h_filterCache(id self, SEL _cmd, id data) {
    id nd = MKRenderArmed() ? MKRewriteDeepText(data) : data;
    return ((id (*)(id, SEL, id))o_filterCache)(self, _cmd, nd);
}

static void MKInstallWeatherHooks(void) {
    o_gmUpdateItem = MKHook(objc_getClass("GMWatermarkItemCallback"),
                            MKSEL(updateItemWithId:withContent:), (IMP)h_gmUpdateItem, "Render_Push");
    o_gmGetContent = MKHook(objc_getClass("GPUMarkImageFilter"),
                            MKSEL(getWatermarkItemContentWithId:), (IMP)h_gmGetContent, "Render_PullFilter");
    o_gmGetContent2 = MKHook(objc_getClass("GMCoreRender"),
                             MKSEL(getWatermarkItemContentWithId:), (IMP)h_gmGetContent2, "Render_PullCore");
    o_gmGetContentAsync = MKHook(objc_getClass("GMCVPixelBuffer"),
                                 MKSEL(getWatermarkItemContentWithId:withCompletion:),
                                 (IMP)h_gmGetContentAsync, "Render_PullAsync");

    // ⑥⑦ 拍照瞬间 / 缓存这两条绕过 push-pull 的路径
    o_renderMarkData = MKHook(objc_getClass("GPUMarkImageFilter"),
                              MKSEL(renderMarkWithInputTexture:andSize:andData:),
                              (IMP)h_renderMarkData, "Render_FinalData");
    o_filterCache = MKHook(objc_getClass("GPUMarkImageFilter"),
                           MKSEL(filterCacheDataWithData:),
                           (IMP)h_filterCache, "Render_Cache");
    o_renderMarkPlain = MKHook(objc_getClass("GPUMarkImageFilter"),
                               MKSEL(renderMarkWithInputTexture:andSize:),
                               (IMP)h_renderMarkPlain, "Render_PlainObserve");

    // 快门入口（用来点亮渲染闸门）
    o_previewCapture = MKHook(objc_getClass("GLPreviewView"),
                              MKSEL(capturePhotoWithFactor:outerEffect:complete:),
                              (IMP)h_previewCapture, "Gate_PreviewCapture");
    o_deviceCapture = MKHook(objc_getClass("GLVideoDevice"),
                             MKSEL(capturePhoto:), (IMP)h_deviceCapture, "Gate_DeviceCapture");
    o_singleCapture = MKHook(objc_getClass("GLSingleCapture"),
                             MKSEL(capturePhoto), (IMP)h_singleCapture, "Gate_SingleCapture");

    // 天气模型（保持原有）
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

    // GPS 也钉死：截图里显示的 30.583/104.079 是 App 用我们伪造的 CLLocation 自己写的，
    // 但只要有任意一条路径读到真坐标就会漏，这里显式覆盖一层保险。
    //
    // 格式说明（纠正一个常见误解）：
    //   kCGImagePropertyGPSLatitude 写给 CGImageDestination 时，Apple 规定是
    //   「NSNumber，带符号的十进制度数」。EXIF 二进制里的度分秒有理数是 ImageIO
    //   序列化时自己拆的；直接塞 @[deg,min,sec] 反而会被 ImageIO 忽略甚至写坏。
    //   所以默认写 NSNumber。想强制成数组可把下面的宏改成 1（不推荐）。
#define MK_GPS_DMS 0
    if (CFG().locOn) {
        NSMutableDictionary *gps = [mut[(id)kCGImagePropertyGPSDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
        gps[(id)kCGImagePropertyGPSVersion] = @[@2, @(2), @(0), @(0)];

#if MK_GPS_DMS
        double alat = fabs(CFG().lat), alng = fabs(CFG().lng);
        int d1 = (int)alat, m1 = (int)((alat - d1) * 60);
        double s1 = (alat - d1 - m1 / 60.0) * 3600.0;
        int d2 = (int)alng, m2 = (int)((alng - d2) * 60);
        double s2 = (alng - d2 - m2 / 60.0) * 3600.0;
        gps[(id)kCGImagePropertyGPSLatitude]  = @[@(d1), @(m1), @(s1)];
        gps[(id)kCGImagePropertyGPSLongitude] = @[@(d2), @(m2), @(s2)];
        MKLOG_ONCE(@"★ EXIF GPS(DMS) %d°%d'%.2f\" %d°%d'%.2f\"", d1, m1, s1, d2, m2, s2);
#else
        gps[(id)kCGImagePropertyGPSLatitude]  = @(fabs(CFG().lat));
        gps[(id)kCGImagePropertyGPSLongitude] = @(fabs(CFG().lng));
        MKLOG_ONCE(@"★ EXIF GPS(十进制) %@,%@", gps[(id)kCGImagePropertyGPSLatitude],
                   gps[(id)kCGImagePropertyGPSLongitude]);
#endif

        gps[(id)kCGImagePropertyGPSLatitudeRef]  = (CFG().lat >= 0) ? @"N" : @"S";
        gps[(id)kCGImagePropertyGPSLongitudeRef] = (CFG().lng >= 0) ? @"E" : @"W";
        mut[(id)kCGImagePropertyGPSDictionary]   = gps;
    }

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
            MKRebindAllImages(tab, 1, "EXIF", YES, YES);   // 强制放行 marki_cn + 允许 lazy
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

// ============================================================================
//  问题一：坐标系互转
//    iOS CoreLocation / CLLocationManager   → WGS-84
//    苹果地图 MKMapView.centerCoordinate    → GCJ-02
//    腾讯 / 高德                             → GCJ-02
//    百度 BMKLocationManager                 → BD-09
//  CFG 里统一存 WGS-84。喂给各家 SDK 时按它自己的基准换算，
//  否则百度会把"WGS 当成 BD"再反算一次，结果偏 400~600 米 —— 这就是水印和验真对不上的根因。
// ============================================================================
static CLLocationCoordinate2D MKGCJ02FromWGS84(double lat, double lng) {
    if (MKOutOfChina(lat, lng)) return CLLocationCoordinate2DMake(lat, lng);
    double dLat = MKTransLat(lng - 105.0, lat - 35.0);
    double dLng = MKTransLng(lng - 105.0, lat - 35.0);
    double radLat = lat / 180.0 * MK_PI;
    double magic = sin(radLat);
    magic = 1 - MK_EE * magic * magic;
    double sq = sqrt(magic);
    dLat = (dLat * 180.0) / ((MK_AXIS * (1 - MK_EE)) / (magic * sq) * MK_PI);
    dLng = (dLng * 180.0) / (MK_AXIS / sq * cos(radLat) * MK_PI);
    return CLLocationCoordinate2DMake(lat + dLat, lng + dLng);
}

// BD-09 ← GCJ-02（百度官方算法）
static CLLocationCoordinate2D MKBD09FromGCJ02(double lat, double lng) {
    const double x_pi = MK_PI * 3000.0 / 180.0;
    double z = sqrt(lng * lng + lat * lat) + 0.00002 * sin(lat * x_pi);
    double theta = atan2(lat, lng) + 0.000003 * cos(lng * x_pi);
    return CLLocationCoordinate2DMake(z * sin(theta) + 0.006, z * cos(theta) + 0.0065);
}

static CLLocationCoordinate2D MKBD09FromWGS84(double lat, double lng) {
    CLLocationCoordinate2D g = MKGCJ02FromWGS84(lat, lng);
    return MKBD09FromGCJ02(g.latitude, g.longitude);
}

// 当前配置坐标的三种基准
static CLLocationCoordinate2D MKCoordWGS84(void) { return CLLocationCoordinate2DMake(CFG().lat, CFG().lng); }
static CLLocationCoordinate2D MKCoordGCJ02(void) { return MKGCJ02FromWGS84(CFG().lat, CFG().lng); }
static CLLocationCoordinate2D MKCoordBD09(void)  { return MKBD09FromWGS84(CFG().lat, CFG().lng); }

// ---- 百度：-[BMKLocation location] 必须是 BD-09 ----
static IMP o_bmkLoc = NULL;
static id mk_bmkLoc(id self, SEL _cmd) {
    if (CFG().locOn) {
        CLLocationCoordinate2D bd = MKCoordBD09();
        MKLOG_ONCE(@"百度 BMKLocation.location → BD-09 %.6f,%.6f（源 WGS %.6f,%.6f）",
                   bd.latitude, bd.longitude, CFG().lat, CFG().lng);
        return [[CLLocation alloc] initWithLatitude:bd.latitude longitude:bd.longitude];
    }
    return ((id (*)(id, SEL))o_bmkLoc)(self, _cmd);
}

// ---- 腾讯：-[TencentLBSLocation location] 必须是 GCJ-02 ----
static IMP o_tnkLoc = NULL;
static id mk_tnkLoc(id self, SEL _cmd) {
    if (CFG().locOn) {
        CLLocationCoordinate2D gcj = MKCoordGCJ02();
        MKLOG_ONCE(@"腾讯 TencentLBSLocation.location → GCJ-02 %.6f,%.6f", gcj.latitude, gcj.longitude);
        return [[CLLocation alloc] initWithLatitude:gcj.latitude longitude:gcj.longitude];
    }
    return ((id (*)(id, SEL))o_tnkLoc)(self, _cmd);
}

// ---- 高德：-[AMapLocationReGeocode ...] 已由验真段的模型 hook 覆盖，这里只补 CLLocation ----
// ============================================================================
//  坐标转换探针（任务 2）
//
//  二进制里**没有**可 hook 的 ObjC 坐标转换类：
//    _TtC8marki_cn19TransformCoordinate   → 0 个 ObjC 方法（纯 Swift enum/struct）
//    CoordinateTool                       → 0 个 ObjC 方法
//    BMFCoordTransType                    → 只有 -handleMethodCall:result:（Flutter 通道）
//  也就是说 App 的坐标换算是内联在 Swift 里的，没有 selector 可挂。
//
//  实测反推（用你的日志数字）：App 把 WGS(30.585041,104.062257) 算成
//  BD09(30.5911601,104.0687073)，只差 21.6 m —— 即它内部固定做 WGS→BD09，
//  然后贴上 mapType=TENCENT 发出去。所以"700 米偏差"的真正来源是
//  「BD09 值被当成 GCJ 用」，而反查结果又覆盖了我们的地址。
//
//  因此这里只做观测，不做替换：替换通道返回值会破坏 Flutter 的 ABI。
//  真正修地址靠 MKNetHookProtocol 改响应（已生效）。
// ============================================================================

static IMP o_bmfCoord = NULL;

static void h_bmfCoord(id self, SEL _cmd, id call, id result) {
    @try {
        NSString *method = nil;
        @try { method = [call valueForKey:@"method"]; } @catch (NSException *e) {}
        if (method.length) {
            id args = nil;
            @try { args = [call valueForKey:@"arguments"]; } @catch (NSException *e) {}
            MKLog(@"[CoordCh] %@ args=%@", method, args);
        }
    } @catch (NSException *e) {}
    if (o_bmfCoord) ((void (*)(id, SEL, id, id))o_bmfCoord)(self, _cmd, call, result);
}

static void MKProbeCoordConverters(void) {
    const char *names[] = {
        "_TtC8marki_cn19TransformCoordinate", "CoordinateTool", "BMFCoordTransType",
        "BMFCoordinate", "AMapLocationCoordinateConverter", "BMKCoordConverter",
        "BMKCoordinateConverter", "TNKCoordinateConvert", NULL
    };
    for (int i = 0; names[i]; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) { MKLog(@"[CoordProbe] %s : absent", names[i]); continue; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        MKLog(@"[CoordProbe] %s : %u objc methods", names[i], n);
        for (unsigned int k = 0; k < n && k < 12; k++) {
            MKLog(@"     -%s %s", sel_getName(method_getName(ms[k])), method_getTypeEncoding(ms[k]));
        }
        free(ms);
    }

    // Flutter 通道：如果坐标换算走这里，日志会打出 coordConvert 之类的 method 名
    o_bmfCoord = MKHook(objc_getClass("BMFCoordTransType"),
                        MKSEL(handleMethodCall:result:), (IMP)h_bmfCoord, "Coord_BMFChannel");
}

static void MKInstallDatumHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    MKProbeCoordConverters();

    o_bmkLoc = MKHook(objc_getClass("BMKLocation"), NSSelectorFromString(@"location"),
                      (IMP)mk_bmkLoc, "Datum_BMKLocation");
    o_tnkLoc = MKHook(objc_getClass("TencentLBSLocation"), NSSelectorFromString(@"location"),
                      (IMP)mk_tnkLoc, "Datum_TencentLBS");

    CLLocationCoordinate2D w = MKCoordWGS84(), g = MKCoordGCJ02(), b = MKCoordBD09();
    MKLog(@"坐标系基准 WGS=(%.6f,%.6f) GCJ=(%.6f,%.6f) BD=(%.6f,%.6f)",
          w.latitude, w.longitude, g.latitude, g.longitude, b.latitude, b.longitude);
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
    CLLocationCoordinate2D bd = MKBD09FromWGS84(wgs.latitude, wgs.longitude);
    MKLog(@"地图确定 GCJ=(%.6f,%.6f) → 存 WGS=(%.6f,%.6f) → 百度用 BD=(%.6f,%.6f)",
          gcj.latitude, gcj.longitude, wgs.latitude, wgs.longitude, bd.latitude, bd.longitude);
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

@interface MKLogViewController : UIViewController
- (void)shareTap;
@end
@implementation MKLogViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MKC_RGB(20, 20, 26);
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)]; bar.backgroundColor = MKC_RGBA(38, 38, 46, 0.98); [self.view addSubview:bar];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 54, bar.bounds.size.width, 26)]; t.text = @"运行日志"; t.textAlignment = NSTextAlignmentCenter; t.font = [UIFont boldSystemFontOfSize:16]; t.textColor = MKC_TEXT(); [bar addSubview:t];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; close.frame = CGRectMake(10, 52, 60, 30); [close setTitle:@"关闭" forState:UIControlStateNormal]; [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:close];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    share.frame = CGRectMake(bar.bounds.size.width - 140, 52, 60, 30);
    [share setTitle:@"分享" forState:UIControlStateNormal];
    [share setTitleColor:MKC_BLUE() forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareTap) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:share];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem]; clear.frame = CGRectMake(bar.bounds.size.width - 70, 52, 60, 30); [clear setTitle:@"清空" forState:UIControlStateNormal]; [clear setTitleColor:MKC_RED() forState:UIControlStateNormal]; [clear addTarget:self action:@selector(clearTap) forControlEvents:UIControlEventTouchUpInside]; [bar addSubview:clear];
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 96, self.view.bounds.size.width, self.view.bounds.size.height - 96)]; tv.tag = 8002; tv.backgroundColor = MKC_RGB(20, 20, 26); tv.textColor = MKC_RGBA(140, 250, 180, 0.92); tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; tv.editable = NO; tv.text = MKLogWhole(); tv.textContainerInset = UIEdgeInsetsMake(10, 10, 24, 10); [self.view addSubview:tv];
    dispatch_async(dispatch_get_main_queue(), ^{ [tv scrollRangeToVisible:NSMakeRange(tv.text.length ? tv.text.length - 1 : 0, 1)]; });
}
- (void)closeTap { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)shareTap {
    NSString *log = MKLogWhole();
    UIActivityViewController *ac = [[UIActivityViewController alloc] initWithActivityItems:@[log] applicationActivities:nil];
    // iPad 必须给 popover 锚点，否则 present 直接崩
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 60, 1, 1);
    }
    MKLog(@"导出日志 %lu 字节", (unsigned long)log.length);
    [self presentViewController:ac animated:YES completion:nil];
}
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
    self.statusLabel.text = [NSString stringWithFormat:@"%@\n定位：%@  时间：%@  替拍：%@\n天气：%@  反作弊：%@\n时钟：%@  广告：%@", (c.renderOnly ? @"【渲染层】网络全真实" : @"【全伪造】"), Y(c.locOn), Y(c.timeOn), Y(c.photoOn), Y(c.wxOn), Y(c.antiOn), (c.clockScope == 0 ? @"关" : (c.clockScope == 1 ? (gClockHooked ? @"安全" : @"失败") : (gClockHooked ? @"全开" : @"失败"))), c.adBlockOn ? (gAdBlockActive ? @"拦" : @"待注册") : @"关"];
    NSString *img = c.imgPath.length ? c.imgPath : @"@latest"; if (img.length > 28) img = [img substringFromIndex:img.length - 28];
    CLLocationCoordinate2D g2 = MKGCJ02FromWGS84(c.lat, c.lng);
    CLLocationCoordinate2D b2 = MKBD09FromWGS84(c.lat, c.lng);
    self.coordLabel.text = [NSString stringWithFormat:@"WGS %.5f,%.5f  GCJ %.5f,%.5f  BD %.5f,%.5f  ·  %@",
                            c.lat, c.lng, g2.latitude, g2.longitude, b2.latitude, b2.longitude, img];
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
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"设置拍摄时间"
                             message:@"格式：yyyy-MM-dd HH:mm:ss（年份可随意改）"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = c.fakeTime.length ? c.fakeTime : @"2026-10-01 12:00:00";
            tf.placeholder = @"2026-10-01 12:00:00";
            tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            NSString *txt = [ac.textFields.firstObject.text
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!txt.length) return;

            // 手动解析，不走 NSDateFormatter（它已被我们 hook）
            int Y = 0, M = 0, D = 0, h = 0, m = 0, sec = 0;
            if (sscanf(txt.UTF8String, "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &sec) < 5) {
                MKAlert(@"格式不对", @"要形如 2026-10-01 12:00:00（年月日 空格 时分秒）");
                return;
            }
            if (Y < 1970 || Y > 2099 || M < 1 || M > 12 || D < 1 || D > 31) {
                MKAlert(@"日期越界", [NSString stringWithFormat:@"年=%d 月=%d 日=%d", Y, M, D]);
                return;
            }
            if (h < 0 || h > 23 || m < 0 || m > 59 || sec < 0 || sec > 59) {
                MKAlert(@"时间越界", [NSString stringWithFormat:@"%d:%d:%d", h, m, sec]);
                return;
            }

            c.fakeTime = [NSString stringWithFormat:@"%04d-%02d-%02d %02d:%02d:%02d", Y, M, D, h, m, sec];
            c.timeOn = YES;
            [c save];
            MKRefreshFakeDate();          // 内部会同步 C 层时钟偏移
            [weakSelf refreshStatus];
            MKLog(@"假时间已设为 %@", c.fakeTime);
            MKSnack([NSString stringWithFormat:@"假时间 %@", c.fakeTime]);
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
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
    if (idx == 4) {                       // 底层时钟：安全模式选择
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"底层时钟（有水印时间才需要开）"
                             message:@"改的是 C 层 time()/clock_gettime()。范围越大越准，也越容易崩。"
                      preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weakSelf = self;

        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            MKSetClockScope(0); [weakSelf refreshStatus]; MKSnack(@"底层时钟已关");
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"安全模式（只改 GPUMarkSDK，推荐）"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            MKSetClockScope(1); [weakSelf refreshStatus]; MKSnack(@"安全模式：只改 GPUMarkSDK");
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"全开（白名单全改，可能闪退）"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            MKSetClockScope(2); [weakSelf refreshStatus]; MKSnack(@"已全开，注意观察是否闪退");
        }]];
        // 最终方案：网络/定位/时间全部放行真实，只在水印画进图之前换文本
        [ac addAction:[UIAlertAction actionWithTitle:@"只改渲染层（网络全真实，推荐）"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            MKFakeCfg *cc = CFG();
            cc.renderOnly = YES;
            cc.safeClockOn = NO;
            cc.clockScope = 0;
            cc.locOn = YES;          // 只给渲染层用（各 getter 在 renderOnly 下已直通）
            cc.timeOn = YES;
            if (gClockHooked) MKRevertClockHook();
            [cc save];
            MKLog(@"MODE=RENDER_ONLY 网络/定位/时间全部真实，只在渲染层换文本");
            [weakSelf refreshStatus];
            MKSnack(@"只改渲染层：服务端验真应全绿");
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭渲染层模式"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            MKFakeCfg *cc = CFG();
            cc.renderOnly = NO;
            [cc save];
            [weakSelf refreshStatus];
            MKSnack(@"已退出渲染层模式");
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

        if (ac.popoverPresentationController) {
            ac.popoverPresentationController.sourceView = b;
            ac.popoverPresentationController.sourceRect = b.bounds;
        }
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (idx == 5) {                       // 去广告
        c.adBlockOn = YES; [c save];
        MKInstallDeferredHooks();
        MKInstallAdBlock();
        [self refreshStatus];
        MKSnack(gAdBlockActive ? @"去广告已启用" : @"去广告注册失败，重启再试");
        return;
    }

    if (idx == 6) {                       // 全部关闭
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"全部关闭" message:@"所有篡改暂停，hook 保留并直通原实现" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确认关闭" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            c.locOn = NO; c.timeOn = NO; c.wxOn = NO;
            c.photoOn = NO; c.photoAlways = NO; c.photoUntil = 0;
            c.antiOn = NO; c.safeClockOn = NO; c.clockScope = 0;
            MKRevertClockHook();
            [c save]; MKRefreshFakeDate(); [weakSelf refreshStatus]; MKSnack(@"已全部关闭");
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

// 前向声明：协议里用到，定义在本段之后
static BOOL MKIsGeoURL(NSURL *url);
static NSData *MKRewriteGeoData(NSData *data, NSURL *url);

// ============================================================================
//  统一网络劫持协议
//    · 广告      → 立即 -999 失败（保持原去广告行为）
//    · 地理接口  → 转发后改写响应 JSON（地址/坐标）
//    · getNewWatermark → 落盘请求体 + 响应体（防伪码取证）
//
//  为什么必须走 NSURLProtocol 而不是 completionHandler：
//    marki 用 AFNetworking 的 delegate 模式（dataTaskWithRequest: 无 handler +
//    NSURLSessionDataDelegate），completionHandler 那条路根本不会被调用 ——
//    上一版 [Geo] handler wrapped 一次都没打印就是这个原因。
// ============================================================================

@interface MKNetHookProtocol : NSURLProtocol
+ (NSArray<NSString *> *)mk_adKeywords;
@end

@implementation MKNetHookProtocol

+ (NSArray<NSString *> *)mk_adKeywords {
    static NSArray *a = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[@"pangolin", @"snssdk", @"bytedance", @"pangle", @"byteimg.com/ad", @"gdt.qq.com", @"e.qq.com", @"adsmind", @"adnet.qq", @"kuaishou", @"gifshow", @"kwai", @"cpro", @"mobads", @"baidu.com/ad", @"union.baidu", @"jd.com/ad", @"tanx.com", @"alimama", @"umeng.com/ad", @"/api/ad", @"/ad/get", @"/adx", @"/splash/ad", @"/api/v1/ad"]; });
    return a;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    // 自循环保护：我们转发出去的请求带这个标记，直接放过
    if ([NSURLProtocol propertyForKey:@"MKHandled" inRequest:request]) return NO;

    // getNewWatermark 不再走本协议：它必须原封不动地由 App 自己发出去。
    // 上一版用新 session 转发 → 服务端返回 0 字节 → 防伪码没有服务端记录。
    if (MKIsGeoURL(request.URL))          return YES;      // 地理接口改写（明文 JSON，安全）
    if (gAdBlockActive && [NSURLProtocol propertyForKey:@"MKAdBlocked" inRequest:request] == nil) {
        NSString *s = request.URL.absoluteString.lowercaseString;
        for (NSString *k in [self mk_adKeywords]) if ([s containsString:k]) return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }

// 抓一份 App 自己用的 NSURLSessionConfiguration（在 session 创建时记录），
// 转发时用它 + 去掉我们的 protocol。这样 HTTPAdditionalHeaders / Cookie /
// 超时 / TLS 最低版本全部和 App 一致，不会再出「服务端返 0 字节」。
static NSURLSessionConfiguration *gAppSessionConfig = nil;

static IMP o_sessionWithConfig = NULL;

static id h_sessionWithConfig(id self, SEL _cmd, NSURLSessionConfiguration *cfg,
                              id delegate, id queue) {
    if (cfg && !gAppSessionConfig) {
        @try { gAppSessionConfig = [cfg copy]; } @catch (NSException *e) {}
        if (gAppSessionConfig) {
            MKLog(@"captured app session config: headers=%lu, protoClasses=%lu",
                  (unsigned long)gAppSessionConfig.HTTPAdditionalHeaders.count,
                  (unsigned long)gAppSessionConfig.protocolClasses.count);
        }
    }
    return ((id (*)(id, SEL, id, id, id))o_sessionWithConfig)(self, _cmd, cfg, delegate, queue);
}

// 转发用 session：优先克隆 App 配置，拿不到才退回 shared/default
static NSURLSession *MKForwardSession(void) {
    static NSURLSession *sess = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = nil;

        if (gAppSessionConfig) {
            @try { c = [gAppSessionConfig copy]; } @catch (NSException *e) { c = nil; }
        }
        if (!c) {
            MKLog(@"WARN: app session config not captured, fallback to default");
            c = [NSURLSessionConfiguration defaultSessionConfiguration];
        }

        // 关键：把我们的协议从克隆配置里摘掉，否则转发会再被自己拦一次
        NSMutableArray *pc = [NSMutableArray array];
        for (id k in c.protocolClasses) if (k != [MKNetHookProtocol class]) [pc addObject:k];
        c.protocolClasses = pc;

        c.timeoutIntervalForRequest  = 20;
        c.timeoutIntervalForResource = 30;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        c.HTTPShouldSetCookies = YES;
        c.HTTPCookieStorage = c.HTTPCookieStorage ?: [NSHTTPCookieStorage sharedHTTPCookieStorage];

        sess = [NSURLSession sessionWithConfiguration:c delegate:nil delegateQueue:nil];
        MKLog(@"forward session ready: headers=%lu cookies=%d",
              (unsigned long)c.HTTPAdditionalHeaders.count, (int)c.HTTPShouldSetCookies);
    });
    return sess;
}

// 把 HTTPBodyStream 读成 NSData（并回填到可变请求，保证转发仍能发出）
static NSData *MKReadBody(NSMutableURLRequest *req) {
    NSData *b = req.HTTPBody;
    if (b) return b;
    NSInputStream *st = req.HTTPBodyStream;
    if (!st) return nil;
    @try {
        [st open];
        NSMutableData *out = [NSMutableData data];
        uint8_t buf[4096];
        NSInteger n = 0;
        while ((n = [st read:buf maxLength:sizeof(buf)]) > 0) [out appendBytes:buf length:(NSUInteger)n];
        [st close];
        if (out.length) {
            req.HTTPBody = out;                  // 回填，转发还能用
            [req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)out.length]
                  forHTTPHeaderField:@"Content-Length"];
        }
        return out.length ? out : nil;
    } @catch (NSException *e) {
        MKLog(@"[WM] read body stream failed: %@", e.reason);
        return nil;
    }
}

static NSString *MKPreview(NSData *d, NSUInteger maxLen) {
    if (!d.length) return @"(empty)";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [NSString stringWithFormat:@"(binary %lu B)", (unsigned long)d.length];
    if (s.length > maxLen) s = [[s substringToIndex:maxLen] stringByAppendingString:@"...(truncated)"];
    return s;
}

// 防伪码取证（delegate 层）：请求体 + 完整响应体落盘 + Base64
static void MKDumpWatermark(NSString *url, NSString *method, NSDictionary *headers,
                            NSData *reqBody, NSData *respBody, NSInteger status) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [doc stringByAppendingPathComponent:@"mk_watermark_dump.txt"];

    NSString *b64 = @"";
    if (respBody.length) {
        b64 = [respBody base64EncodedStringWithOptions:0];
    }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"\n===== %@ =====\n", [NSDate date]];
    [out appendFormat:@"URL    : %@\n", url];
    [out appendFormat:@"METHOD : %@\n", method];
    [out appendFormat:@"HEADERS: %@\n", headers];
    [out appendFormat:@"BODY   : %lu B\n%@\n", (unsigned long)reqBody.length, MKPreview(reqBody, 2000)];
    [out appendFormat:@"STATUS : %ld\n", (long)status];
    [out appendFormat:@"RESP   : %lu B\n%@\n", (unsigned long)respBody.length, MKPreview(respBody, 4000)];
    [out appendFormat:@"RESP_B64 (%lu chars):\n%@\n", (unsigned long)b64.length, b64];

    // 响应原文单独存一份，方便直接拉出来看
    if (respBody.length) {
        NSString *bin = [doc stringByAppendingPathComponent:@"mk_wm_resp.bin"];
        [respBody writeToFile:bin atomically:YES];
        MKLog(@"[WM] resp saved: %@ (%lu B)", bin, (unsigned long)respBody.length);
    }

    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch (NSException *e) { MKLog(@"[WM] dump write failed: %@", e.reason); }
    }

    MKLog(@"[WM] %@ status=%ld body=%lu B resp=%lu B", url,
          (long)status, (unsigned long)reqBody.length, (unsigned long)respBody.length);
    MKLog(@"[WMBody] %@", MKPreview(reqBody, 1200));
    MKLog(@"[WMResp] %@", MKPreview(respBody, 1200));
    if (b64.length) {
        NSString *head = b64.length > 1600 ? [[b64 substringToIndex:1600] stringByAppendingString:@"...(cut)"] : b64;
        MKLog(@"[WMRespB64] %@", head);
    }
}

// ---------------------------------------------------------------------------
//  NSURLSessionDataDelegate 层嗅探：请求/响应全部由 App 自己发，我们只旁听
//
//  为什么要枚举类：marki 的网络栈是 WindMill / JCORE / 各家广告 SDK 各一套，
//  二进制里有 30 个类实现了 -URLSession:dataTask:didReceiveData:。
//  逐个挂上去，才能不依赖具体哪个 SDK 在跑。
// ---------------------------------------------------------------------------

// ---- 原实现登记表：同一个 C 函数挂在多个类上，必须按 (类, SEL) 分别记 orig ----
#define MK_SNIFF_MAX 8
typedef struct { Class cls; SEL sel; IMP orig; } MKSniffSlot;
static MKSniffSlot gSniffSlots[256];
static int         gSniffSlotCount = 0;

static void MKSniffRemember(Class cls, SEL sel, IMP orig) {
    if (gSniffSlotCount >= 256) return;
    gSniffSlots[gSniffSlotCount].cls = cls;
    gSniffSlots[gSniffSlotCount].sel = sel;
    gSniffSlots[gSniffSlotCount].orig = orig;
    gSniffSlotCount++;
}

static IMP MKSniffOrig(id self, SEL sel) {
    Class k = object_getClass(self);
    while (k) {
        for (int i = 0; i < gSniffSlotCount; i++) {
            if (gSniffSlots[i].cls == k && sel_isEqual(gSniffSlots[i].sel, sel)) return gSniffSlots[i].orig;
        }
        k = class_getSuperclass(k);
    }
    return NULL;
}

// 嗅探表：request 登记 / 响应累积，全部按 taskIdentifier 索引
static NSMutableDictionary<NSNumber *, NSString *>      *gTaskURL  = nil;
static NSMutableDictionary<NSNumber *, NSData *>        *gTaskBody = nil;
static NSMutableDictionary<NSNumber *, NSMutableData *> *gTaskData = nil;
static NSLock *gSniffLock = nil;

static void MKSniffInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTaskURL  = [NSMutableDictionary dictionary];
        gTaskBody = [NSMutableDictionary dictionary];
        gTaskData = [NSMutableDictionary dictionary];
        gSniffLock = [NSLock new];
    });
}

static BOOL MKIsWatermarkURLString(NSString *s) {
    if (!s.length) return NO;
    return ([s containsString:@"getNewWatermark"] || [s containsString:@"getWatermark"]);
}

// 分片累积（copy 一份，App 的请求/响应完全不受影响）→ 然后必须调原实现
static void h_didReceiveData(id self, SEL _cmd, id session, id task, NSData *data) {
    @try {
        MKSniffInit();
        NSNumber *key = @([task taskIdentifier]);
        NSString *u = gTaskURL[key];
        if (MKIsWatermarkURLString(u) && data.length) {
            [gSniffLock lock];
            NSMutableData *buf = gTaskData[key];
            if (!buf) { buf = [NSMutableData data]; gTaskData[key] = buf; }
            [buf appendData:data];
            [gSniffLock unlock];
        }
    } @catch (NSException *e) {}

    IMP o = MKSniffOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, session, task, data);
}

// 完成：落盘 + Base64，然后调原实现
static void h_didComplete(id self, SEL _cmd, id session, id task, NSError *error) {
    @try {
        MKSniffInit();
        NSNumber *key = @([task taskIdentifier]);
        NSString *u = gTaskURL[key];
        if (MKIsWatermarkURLString(u)) {
            NSHTTPURLResponse *resp = (NSHTTPURLResponse *)[task response];

            [gSniffLock lock];
            NSMutableData *buf = gTaskData[key];
            NSData *body = gTaskBody[key];
            [gTaskData removeObjectForKey:key];
            [gTaskBody removeObjectForKey:key];
            [gTaskURL  removeObjectForKey:key];
            [gSniffLock unlock];

            MKDumpWatermark(u, [task originalRequest].HTTPMethod ?: @"POST",
                            resp.allHeaderFields, body, buf ?: [NSData data],
                            resp ? resp.statusCode : -1);
            MKClockGatePop("wm-done");          // 请求结束立刻恢复假时间
            if (error) MKLog(@"[WM] completed with error: %@", error.localizedDescription);
        }
    } @catch (NSException *e) {
        MKLog(@"[WM] complete handler exception: %@", e.reason);
    }

    IMP o = MKSniffOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, session, task, error);
}

// 遍历全部已加载类，把这些 delegate 方法都挂上。
// marki 的网络栈有 WindMill / JCORE / 各家广告 SDK 各一套，二进制里 30 个类实现了它。
static void MKInstallSessionSniffer(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    MKSniffInit();

    SEL sData = @selector(URLSession:dataTask:didReceiveData:);
    SEL sComp = @selector(URLSession:task:didCompleteWithError:);

    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) { MKLog(@"[Sniff] objc_getClassList failed"); return; }

    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)numClasses);
    numClasses = objc_getClassList(classes, numClasses);

    int scanned = 0, hooked = 0;

    for (int i = 0; i < numClasses; i++) {
        Class c = classes[i];
        if (!c) continue;
        scanned++;

        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);      // 只看本类自己实现的
        BOOL hasData = NO, hasComp = NO;
        for (unsigned int k = 0; k < n; k++) {
            SEL sl = method_getName(ms[k]);
            if (sel_isEqual(sl, sData)) hasData = YES;
            else if (sel_isEqual(sl, sComp)) hasComp = YES;
        }
        free(ms);

        if (hasData) {
            Method m = class_getInstanceMethod(c, sData);
            if (m && method_getImplementation(m) != (IMP)h_didReceiveData) {
                MKSniffRemember(c, sData, method_getImplementation(m));
                method_setImplementation(m, (IMP)h_didReceiveData);
                hooked++;
            }
        }
        if (hasComp) {
            Method m = class_getInstanceMethod(c, sComp);
            if (m && method_getImplementation(m) != (IMP)h_didComplete) {
                MKSniffRemember(c, sComp, method_getImplementation(m));
                method_setImplementation(m, (IMP)h_didComplete);
                hooked++;
            }
        }
    }
    free(classes);

    MKLog(@"[Sniff] scanned %d classes, hooked %d delegate methods", scanned, hooked);
}

- (void)startLoading {
    NSURLRequest *req = self.request;

    // ① 广告：直接失败
    if (gAdBlockActive && !MKIsGeoURL(req.URL)) {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
                                       userInfo:@{ NSLocalizedDescriptionKey : @"blocked by MarkiFake" }];
        [self.client URLProtocol:self didFailWithError:err];
        return;
    }

    BOOL isGeo = MKIsGeoURL(req.URL);

    NSMutableURLRequest *fwd = [req mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"MKHandled" inRequest:fwd];   // 防自循环

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *t = [MKForwardSession() dataTaskWithRequest:fwd
                                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        if (err) { [self_.client URLProtocol:self_ didFailWithError:err]; return; }

        NSData *out = data;
        if (isGeo) {
            @try { out = MKRewriteGeoData(data, req.URL); }
            @catch (NSException *e) { MKLog(@"[Geo] rewrite exception: %@", e.reason); out = data; }
        }
        if (!resp) {
            NSError *e2 = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse
                                          userInfo:@{ NSLocalizedDescriptionKey : @"MKNetHook: nil response" }];
            [self_.client URLProtocol:self_ didFailWithError:e2];
            return;
        }
        [self_.client URLProtocol:self_ didReceiveResponse:resp
               cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (out.length) [self_.client URLProtocol:self_ didLoadData:out];
        [self_.client URLProtocolDidFinishLoading:self_];
    }];
    [t resume];
}

- (void)stopLoading { }

@end

static IMP o_setProtocolClasses = NULL;
static void h_setProtocolClasses(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *arr = [NSMutableArray arrayWithObject:[MKNetHookProtocol class]];
    for (id c in classes) if (c != [MKNetHookProtocol class]) [arr addObject:c];
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
    for (NSString *k in [MKNetHookProtocol mk_adKeywords]) {
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

// 诊断用：把地图 / 反查 / 验真相关的请求全打到日志里
static BOOL MKIsInterestingURL(NSString *urlStr) {
    if (!urlStr.length) return NO;
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"map", @"location", @"verify", @"confirm", @"tencent", @"baidu",
                 @"regeo", @"geocode", @"address", @"watermark", @"hash", @"exif"];
    });
    NSString *low = urlStr.lowercaseString;
    for (NSString *k in keys) if ([low containsString:k]) return YES;
    return NO;
}

static void MKLogNetReq(NSString *urlStr) {
    if (!MKIsInterestingURL(urlStr)) return;
    NSString *s = urlStr.length > 300 ? [urlStr substringToIndex:300] : urlStr;
    MKLog(@"[NetReq] %@", s);
}

// ============================================================================
//  地理接口响应改写（解决 sign 限制：参数不能动，只能改返回值）
//
//  App 请求：
//    /wms/location/getPlaceSuggestion?...&location=<WGS>&mapType=baidu&...&sign=xxx
//    /wms/location/getReversCoding?location=<..>&mapType=TENCENT&sign=xxx
//  location 带 sign，改一个字符就验签失败 → 只能在 completionHandler 里替换返回体。
// ============================================================================

static BOOL MKIsGeoURL(NSURL *url) {
    // 渲染层模式：地理请求连拦都不拦，保证 getPlaceSuggestion 拿到的是服务端原话，
    // 这样后续 getNewWatermark 的 placeId 与坐标天然自洽，不会再有 resp=0。
    if (CFG().renderOnly) return NO;
    if (!url) return NO;
    NSString *s = url.absoluteString;
    if (!s.length) return NO;
    if (![s containsString:@"markiapp.com"]) return NO;     // 只碰自家接口
    return [s containsString:@"getPlaceSuggestion"]
        || [s containsString:@"getReversCoding"]
        || [s containsString:@"getReverseCoding"];
}

// gzip 解压（响应可能被 Content-Encoding: gzip 包过一层）
static NSData *MKGunzip(NSData *data) {
    if (data.length < 18) return nil;
    const uint8_t *b = (const uint8_t *)data.bytes;
    if (!(b[0] == 0x1f && b[1] == 0x8b)) return nil;       // 不是 gzip

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) return nil;

    NSMutableData *out = [NSMutableData dataWithCapacity:data.length * 4];
    zs.next_in  = (Bytef *)b;
    zs.avail_in = (uInt)data.length;

    uint8_t buf[16384];
    int rc = Z_OK;
    do {
        zs.next_out  = buf;
        zs.avail_out = sizeof(buf);
        rc = inflate(&zs, Z_NO_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) break;
        NSUInteger got = sizeof(buf) - zs.avail_out;
        if (got) [out appendBytes:buf length:got];
        if (out.length > 8 * 1024 * 1024) break;            // 安全阀
    } while (rc != Z_STREAM_END && zs.avail_in > 0);

    inflateEnd(&zs);
    return out.length ? out : nil;
}

// 1 = 连坐标一起改（会破坏 placeId↔location 自洽，服务端可能返回空）
// 0 = 只改显示文本，坐标 / placeId / 行政区划全部原样透传   ← 默认
#define MK_GEO_REWRITE_COORD 0

// 只列「纯展示、不参与服务端校验」的字段。
// address / addr / detailAddress / 各级行政区划故意排除：
// getNewWatermark 的 78 B 密文里可能带着 location+placeId，一旦和改写后的字段对不上
// 服务端就返回 0 字节（这条已由运行时日志证实：唯一成功那次在所有 Geo 改写之前）。
static NSSet *MKAddrKeys(void) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"name", @"poiName", @"displayName", @"suggestion",
            @"formattedAddress", @"fullAddress", @"addressName",
        ]];
    });
    return s;
}

// 这些 key 的整棵子树一律原样透传，绝不递归改写
static BOOL MKIsGeoOpaqueKey(NSString *k) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"location", @"point", @"coordinate", @"geoPoint", @"center",
            @"placeId", @"id", @"poiId", @"uid", @"poiUid",
            @"province", @"city", @"district", @"town", @"adcode", @"citycode",
            @"category", @"tag", @"tagId", @"distance",
        ]];
    });
    return [s containsObject:k];
}

static BOOL MKIsLatKey(NSString *k) {
    NSString *l = k.lowercaseString;
    return [l isEqualToString:@"latitude"] || [l isEqualToString:@"lat"]
        || [l isEqualToString:@"pointlat"] || [l isEqualToString:@"bd09lat"]
        || [l isEqualToString:@"gcjlat"];
}
static BOOL MKIsLngKey(NSString *k) {
    NSString *l = k.lowercaseString;
    return [l isEqualToString:@"longitude"] || [l isEqualToString:@"lng"]
        || [l isEqualToString:@"lon"] || [l isEqualToString:@"pointlng"]
        || [l isEqualToString:@"bd09lng"] || [l isEqualToString:@"gcjlng"];
}

// 递归改写。coordinate 用「和请求 mapType 同基准」的值，
// 否则地图上的图钉会和我们给的地址对不上（虽然地址已经是我们写的）。
static id MKRewriteGeoJSON(id obj, CLLocationCoordinate2D coord, int *hits) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)obj count]];
        for (id key in (NSDictionary *)obj) {
            if (![key isKindOfClass:[NSString class]]) { out[key] = MKRewriteGeoJSON([(NSDictionary *)obj objectForKey:key], coord, hits); continue; }
            NSString *k = (NSString *)key;
            id v = [(NSDictionary *)obj objectForKey:k];

            // ① 不透明子树：location / placeId / 行政区划 … 原样透传，不递归
            if (MKIsGeoOpaqueKey(k)) {
                out[k] = v;
                continue;
            }

            // ② 只改纯展示文本
            if ([MKAddrKeys() containsObject:k] && CFG().addr.length) {
                out[k] = CFG().addr;
                (*hits)++;
                continue;
            }

            // ③ 坐标：默认不动（动了 placeId 就对不上）
            if (MKIsLatKey(k)) {
#if MK_GEO_REWRITE_COORD
                out[k] = [v isKindOfClass:[NSString class]]
                       ? [NSString stringWithFormat:@"%.8f", coord.latitude]
                       : @(coord.latitude);
                (*hits)++;
#else
                out[k] = v;
#endif
                continue;
            }
            if (MKIsLngKey(k)) {
#if MK_GEO_REWRITE_COORD
                out[k] = [v isKindOfClass:[NSString class]]
                       ? [NSString stringWithFormat:@"%.8f", coord.longitude]
                       : @(coord.longitude);
                (*hits)++;
#else
                out[k] = v;
#endif
                continue;
            }

            out[k] = MKRewriteGeoJSON(v, coord, hits);
        }
        return out;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
        for (id v in (NSArray *)obj) [out addObject:MKRewriteGeoJSON(v, coord, hits)];
        return out;
    }
    return obj;
}

// 按 mapType 选基准：baidu=BD09，TENCENT/AMAP=GCJ02，其它=WGS
static CLLocationCoordinate2D MKCoordForURL(NSURL *url, const char **datumName) {
    NSString *s = url.absoluteString.uppercaseString;
    if ([s containsString:@"MAPTYPE=BAIDU"]) { if (datumName) *datumName = "BD09";    return MKCoordBD09(); }
    if ([s containsString:@"MAPTYPE=TENCENT"] ||
        [s containsString:@"MAPTYPE=AMAP"])   { if (datumName) *datumName = "GCJ02";   return MKCoordGCJ02(); }
    if (datumName) *datumName = "WGS84";
    return MKCoordWGS84();
}

static NSData *MKRewriteGeoData(NSData *data, NSURL *url) {
    if (!data.length) return data;
    if (CFG().renderOnly) return data;      // 渲染层模式：网络数据全部原样，让服务端完美验签
    if (!CFG().locOn || !CFG().addr.length) return data;

    NSData *plain = data;
    const uint8_t *b = (const uint8_t *)data.bytes;
    if (data.length > 2 && b[0] == 0x1f && b[1] == 0x8b) {
        plain = MKGunzip(data);
        if (!plain) { MKLog(@"[Geo] gzip inflate failed, pass through"); return data; }
        MKLog(@"[Geo] gzip %lu -> %lu B", (unsigned long)data.length, (unsigned long)plain.length);
    }

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:plain options:0 error:&err];
    if (!json) {
        MKLog(@"[Geo] not JSON (%lu B): %@", (unsigned long)plain.length, err.localizedDescription);
        return data;
    }

    // 原始返回体（截断），用来核对替换是否生效
    NSString *raw = [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
    if (raw.length > 700) raw = [[raw substringToIndex:700] stringByAppendingString:@"...(truncated)"];
    MKLog(@"[GeoRaw] %@", raw);

    const char *datum = "WGS84";
    CLLocationCoordinate2D c = MKCoordForURL(url, &datum);

    int hits = 0;
    id out = MKRewriteGeoJSON(json, c, &hits);
    if (hits == 0) {
        MKLog(@"[Geo] no field matched (addr=%@), pass through", CFG().addr);
        return data;
    }

    NSData *nd = [NSJSONSerialization dataWithJSONObject:out options:0 error:&err];
    if (!nd) { MKLog(@"[Geo] re-serialize failed: %@", err.localizedDescription); return data; }

    NSString *after = [[NSString alloc] initWithData:nd encoding:NSUTF8StringEncoding];
    if (after.length > 400) after = [[after substringToIndex:400] stringByAppendingString:@"..."];
    MKLog(@"[Geo] rewrote %d fields -> addr=%@ coord=%.6f,%.6f(%s)", hits, CFG().addr, c.latitude, c.longitude, datum);
    MKLog(@"[GeoNew] %@", after);
    return nd;
}

typedef void (^MKDataCompletion)(NSData *, NSURLResponse *, NSError *);

// 包一层 completionHandler：只对地理接口生效，其它原样透传
static id MKWrapDataHandler(id handler, NSURL *url) {
    if (!handler) return handler;
    if (!MKIsGeoURL(url)) return handler;
    if (!CFG().locOn) return handler;

    MKDataCompletion orig = (MKDataCompletion)handler;
    MKDataCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSData *out = data;
        @try {
            out = MKRewriteGeoData(data, url);
        } @catch (NSException *ex) {
            MKLog(@"[Geo] rewrite exception: %@", ex.reason);
            out = data;
        }
        if (orig) orig(out, resp, e);
    };
    MKLog(@"[Geo] handler wrapped for %@", url.path);
    return [wrapped copy];
}

// 把 watermark 任务登记进嗅探表（只读，不改请求）
//   MK_SNIFF_STREAM_BODY = 1 时才去读 HTTPBodyStream（会用 HTTPBody 副本替换，
//   风险自负：极少数服务端对 chunked / Content-Length 敏感）
#define MK_SNIFF_STREAM_BODY 0

static void MKRecordTask(id task, NSURLRequest *req) {
    if (!task || !req) return;
    NSString *u = req.URL.absoluteString;
    if (!MKIsWatermarkURLString(u)) return;

    MKSniffInit();
    NSData *body = req.HTTPBody;
    BOOL streamed = (body == nil && req.HTTPBodyStream != nil);

#if MK_SNIFF_STREAM_BODY
    if (streamed) {
        NSMutableURLRequest *m = [req mutableCopy];
        body = MKReadBody(m);                      // 会消费原 stream，仅调试用
    }
#endif

    NSNumber *key = @([task taskIdentifier]);
    [gSniffLock lock];
    gTaskURL[key] = u;
    if (body.length) gTaskBody[key] = body;
    [gSniffLock unlock];

    MKLog(@"[WM] task#%ld %@ body=%lu B streamed=%d",
          (long)[task taskIdentifier], u, (unsigned long)body.length, (int)streamed);

    // 从这个 task 建立到它完成，C 层 time() 返回真实时间，签名才不会用假时间戳
    MKClockGatePush("wm-sign");
}

static id h_dtReqCb(id self, SEL _cmd, NSURLRequest *req, id cb) {
    // 我们自己转发出去的请求：打日志可以，绝不能再次改写（否则会二次替换）
    if ([NSURLProtocol propertyForKey:@"MKHandled" inRequest:req]) {
        return ((id (*)(id, SEL, id, id))o_dtReqCb)(self, _cmd, req, cb);
    }
    MKLogNetReq(req.URL.absoluteString);
    id wrapped = MKWrapDataHandler(cb, req.URL);
    id task = ((id (*)(id, SEL, id, id))o_dtReqCb)(self, _cmd, MKNeutralize(req), wrapped);
    MKRecordTask(task, req);
    return task;
}
static id h_dtReq(id self, SEL _cmd, NSURLRequest *req) {
    MKLogNetReq(req.URL.absoluteString);
    id task = ((id (*)(id, SEL, id))o_dtReq)(self, _cmd, MKNeutralize(req));
    MKRecordTask(task, req);
    return task;
}
static id h_dtUrlCb(id self, SEL _cmd, NSURL *url, id cb) {
    MKLogNetReq(url.absoluteString);
    id wrapped = MKWrapDataHandler(cb, url);
    return ((id (*)(id, SEL, id, id))o_dtUrlCb)(self, _cmd, MKIsAdURL(url) ? MKBlockedURL() : url, wrapped);
}
static id h_dtUrl(id self, SEL _cmd, NSURL *url) {
    MKLogNetReq(url.absoluteString);
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

// 网络层统一安装：
//   ① MKNetHookProtocol 无条件注册 —— 地理改写 / 防伪码取证都靠它，
//      绝不能跟着 adBlockOn 一起被关掉（上一版就是这么把 [Geo] 全关死的）。
//   ② gAdBlockActive 只控制 canInit 里的广告分支。
static void MKInstallAdBlock(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    [NSURLProtocol registerClass:[MKNetHookProtocol class]];

    // ① 抓 App 自己的 session 配置（Geo 转发用）
    // ② 挂 delegate 嗅探（WM 取证，不改任何请求）
    o_sessionWithConfig = MKHookClass(objc_getClass("NSURLSession"),
                                      @selector(sessionWithConfiguration:delegate:delegateQueue:),
                                      (IMP)h_sessionWithConfig, "Net_CaptureSessionConfig");
    MKInstallSessionSniffer();

    // 把拦截器顶到 protocolClasses 第 0 位，压过 SDK 自己设的
    o_setProtocolClasses = MKHook(objc_getClass("NSURLSessionConfiguration"),
                                  MKSEL(setProtocolClasses:), (IMP)h_setProtocolClasses,
                                  "AdBlock_SetProtocols");

    // 仅做日志的 dataTask 入口（不参与改写，改写已交给 Protocol）
    Class sess = objc_getClass("NSURLSession");
    o_dtReqCb = MKHook(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)h_dtReqCb, "Net_DataTaskReqCb");
    o_dtReq   = MKHook(sess, @selector(dataTaskWithRequest:),                    (IMP)h_dtReq,   "Net_DataTaskReq");
    o_dtUrlCb = MKHook(sess, @selector(dataTaskWithURL:completionHandler:),      (IMP)h_dtUrlCb, "Net_DataTaskUrlCb");
    o_dtUrl   = MKHook(sess, @selector(dataTaskWithURL:),                        (IMP)h_dtUrl,   "Net_DataTaskUrl");
    o_syncReq = MKHookClass(objc_getClass("NSURLConnection"),
                            @selector(sendSynchronousRequest:returningResponse:error:),
                            (IMP)h_syncReq, "NSURLConnection_syncReq");

    gAdBlockActive = CFG().adBlockOn;

    MKLog(@"NET: protocol registered, adblock=%d, %lu keywords",
          (int)gAdBlockActive, (unsigned long)[MKNetHookProtocol mk_adKeywords].count);
}

static void MKSafeInstall(void (*fn)(void), const char *name) { @try { fn(); } @catch (NSException *e) { MKLog(@"✗ 安装器 %s 抛异常: %@", name, e.reason); } @catch (id other) {} }

static void MKInstallAllHooks(void) {
    MKLog(@"========== MarkiFake 启动 ==========");
    MKSafeInstall(MKInstallLocationHooks, "LOCATION");
    MKSafeInstall(MKInstallAntiCheatHooks, "ANTICHEAT");
    MKSafeInstall(MKInstallCameraHooks,   "CAMERA");
    MKSafeInstall(MKInstallWeatherHooks,  "WEATHER");
    MKSafeInstall(MKInstallVerifyHooks,   "VERIFY");
    MKSafeInstall(MKInstallDatumHooks,    "DATUM");
}

static void MKInstallDeferredHooks(void) {
    static BOOL done = NO; if (done) return; done = YES;
    MKSafeInstall(MKInstallTimeHooks, "TIME_OBJC");
    // 请求监控必须无条件装（广告拦截在函数内部自己判断开关）
    MKSafeInstall(MKInstallAdBlock, "NET_ADBLOCK");
    if (CFG().safeClockOn) { @try { MKSetSafeClock(YES); } @catch (NSException *e) {} }
}

static void MKSchedulePanel(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (o_vsInit == NULL) MKInstallCameraHooks();
        if (o_gmUpdateItem == NULL) MKInstallWeatherHooks();
        { static BOOL vDone = NO; if (!vDone) { vDone = YES; MKSafeInstall(MKInstallVerifyHooks, "VERIFY_FG"); MKSafeInstall(MKInstallDatumHooks, "DATUM_FG"); } }
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
