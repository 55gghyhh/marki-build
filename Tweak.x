// =============================================================================
//  MarkiFake  —  markki.cn / 马克水印相机 16.4.1  一体化造假 Tweak
//  定位伪造 · 底层像素缓冲换图 · 拍摄时间 · 天气 · 反作弊归零
//
//  目标 : com.ai.marki        可执行文件 : marki_cn
//  架构 : arm64 / arm64e     最低 iOS : 15.0
//
//  设计参照 TG：ioskuka.dylib（XCamera）的三段式做法，全部用 Runtime API 重写：
//    · 不依赖 libsubstrate，不依赖 Logos 宏 → 可直接被 TrollFools / ElleKit 注入
//    · 每个 hook 都有自己的直通分支，关掉开关就恢复原厂行为
//
//  本文件里所有类名/方法名/类型编码都来自 marki_cn 的静态分析，可复核：
//    MKLocationManager                   -getRecentLocation / -setRecentLocation:
//    MKLocationInfo                      -latitude(d) / -longitude(d) / -address(@)
//    _TtC8marki_cn16MKLocationObject     -latitude(d) / -longitude(d)          [Swift]
//    _TtC8marki_cn19LocationRealManager  -isMockLocation(B)                    [Swift]
//    GLVideoSample                       -initWithPixelBuffer:timeStamp:  @32@0:8^{__CVBuffer=}16d24
//    GLVideoDevice                       -captureOutput:didFinishProcessingPhoto:error:  v40@0:8@16@24@32
//    MKWeatherInfo                       -condTxt(@) -temperature(q) -aqi(q) -humidity(f)
//    NSDateFormatter                     -stringFromDate:
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
#include <time.h>
#include <sys/time.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <math.h>

// 非系统选择器统一用字符串构造，避免 undeclared-selector 警告
#define MKSEL(name) NSSelectorFromString(@#name)

// 拼接用的宏（MKLOG_ONCE 内部用行号区分）
#define MK_CAT2(a, b) a##b
#define MK_CAT(a, b)  MK_CAT2(a, b)

// =============================================================================
//  MARK: - 日志：NSLog + 落盘（真机没电脑也能看）
// =============================================================================

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
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.mkf.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(q, ^{
        @autoreleasepool {
            // 用 CFAbsoluteTime 换算 unix 时间，绕开可能被 hook 的 NSDate/NSDateFormatter
            double t = CFAbsoluteTimeGetCurrent() + 978307200.0;
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n", t, msg];

            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *path = MKLogFilePath();

            struct stat st;
            if (stat(path.UTF8String, &st) == 0 && st.st_size > 512 * 1024) {
                [fm removeItemAtPath:path error:NULL];
            }
            if (![fm fileExistsAtPath:path]) {
                [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                return;
            }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) return;
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {
                NSLog(@"[MKFake] 写日志失败: %@", e.reason);
            }
        }
    });
}

// 只在第一次执行，用于每次拍照都会走到的路径，防止刷屏
#define MKLOG_ONCE(fmt, ...) do { \
    static BOOL MK_CAT(_mk_once_, __LINE__) = NO; \
    if (!MK_CAT(_mk_once_, __LINE__)) { \
        MK_CAT(_mk_once_, __LINE__) = YES; \
        MKLog(fmt, ##__VA_ARGS__); \
    } \
} while (0)

// =============================================================================
//  MARK: - 配置
// =============================================================================

@interface MKFakeCfg : NSObject
@property (nonatomic, assign) double    lat;
@property (nonatomic, assign) double    lng;
@property (nonatomic, copy)   NSString *addr;
@property (nonatomic, copy)   NSString *imgPath;       // 绝对路径 或 "@latest"
@property (nonatomic, assign) BOOL      locOn;
@property (nonatomic, assign) BOOL      photoOn;
@property (nonatomic, assign) BOOL      photoAlways;
@property (nonatomic, assign) double    photoUntil;    // unix 秒
@property (nonatomic, assign) BOOL      timeOn;
@property (nonatomic, copy)   NSString *fakeTime;      // "2026-10-30 09:15:00"
@property (nonatomic, assign) BOOL      wxOn;
@property (nonatomic, copy)   NSString *wxText;
@property (nonatomic, assign) long long wxTemp;
@property (nonatomic, assign) BOOL      antiOn;
@property (nonatomic, assign) BOOL      fill;          // YES 铺满 / NO 完整留白
@property (nonatomic, assign) BOOL      flipY;         // BGRA 直写时是否翻转（花屏/倒图开关）
@property (nonatomic, assign) BOOL      fab;
@property (nonatomic, assign) BOOL      adBlockOn;
@property (nonatomic, assign) NSInteger layer;         // 0 自动 / 1 GLVideoSample / 2 AVCapturePhoto
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
        _lat = 39.9042;
        _lng = 116.4074;
        _addr = @"北京市东城区东长安街";
        _imgPath = @"@latest";
        _fakeTime = @"2026-10-30 09:15:00";
        _wxText = @"晴";
        _wxTemp = 26;
        _antiOn = YES;
        _fill = YES;
        _flipY = NO;   // 真机日志确认 flip=0 才不上下颠倒
        _fab = YES;
        _adBlockOn = YES;
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
    [d setInteger:self.layer forKey:@"mk.layer"];
    [d synchronize];

    MKLog(@"配置已保存 loc=%d(%.6f,%.6f) photo=%d(%@) time=%d(%@) wx=%d(%@) anti=%d layer=%ld fill=%d flip=%d",
          self.locOn, self.lat, self.lng,
          self.photoOn, self.imgPath,
          self.timeOn, self.fakeTime,
          self.wxOn, self.wxText,
          self.antiOn, (long)self.layer, self.fill, self.flipY);
}
@end

static MKFakeCfg *CFG(void) { return [MKFakeCfg shared]; }
static double MKUnixNow(void) { return CFAbsoluteTimeGetCurrent() + 978307200.0; }

// =============================================================================
//  MARK: - Runtime hook 基础设施
// =============================================================================

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

static char MKRetType(Method m) {
    char buf[32] = {0};
    method_getReturnType(m, buf, sizeof(buf));
    return buf[0];
}

// =============================================================================
//  MARK: - 四字符码 / 像素格式判断
// =============================================================================

static NSString *MKFourCC(OSType fmt) {
    char c[5];
    c[0] = (char)((fmt >> 24) & 0xFF);
    c[1] = (char)((fmt >> 16) & 0xFF);
    c[2] = (char)((fmt >>  8) & 0xFF);
    c[3] = (char)( fmt        & 0xFF);
    c[4] = 0;
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) c[i] = '?';
    }
    return [NSString stringWithFormat:@"'%s'(0x%08X)", c, (unsigned)fmt];
}

static BOOL MKIsYUV(OSType fmt) {
    return fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        || fmt == kCVPixelFormatType_420YpCbCr8Planar
        || fmt == kCVPixelFormatType_420YpCbCr8PlanarFullRange
        || fmt == kCVPixelFormatType_422YpCbCr8
        || fmt == kCVPixelFormatType_422YpCbCr8_yuvs;
}

static BOOL MKIs32RGBA(OSType fmt) {
    // 只认 BGRA：ABGR/RGBA 的字节序不同，直写会串色，交给 CoreImage
    return fmt == kCVPixelFormatType_32BGRA;
}

// CVPixelBufferGetAttachments 在新 SDK 里没有（只有 CVBufferGetAttachments）
static void *MKBufferAttachments(CVPixelBufferRef pb) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFDictionaryRef d = CVBufferGetAttachments((CVBufferRef)pb, kCVAttachmentMode_ShouldPropagate);
#pragma clang diagnostic pop
    return (void *)d;
}

// =============================================================================
//  MARK: - 换图：图片来源
// =============================================================================

static UIImage  *gSwapImg = nil;
static NSString *gSwapKey = nil;
static CFAbsoluteTime gSwapLoadedAt = 0;
static BOOL      gSwapFetching = NO;

// 单边最大像素：4096 足够覆盖 1080P/2K 取景，又不至于 12MP 全解码吃内存
#define MK_MAX_PIXEL 4096.0

// 把任意 orientation 的 UIImage 压成 upright 位图，后面就能安全取 CGImage
static UIImage *MKNormalizeUIImage(UIImage *img) {
    if (!img) return nil;
    if (img.imageOrientation == UIImageOrientationUp) return img;
    @try {
        UIGraphicsBeginImageContextWithOptions(img.size, NO, 1.0);
        [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (out) {
            MKLog(@"图片方向已摆正 %ld → up", (long)img.imageOrientation);
            return out;
        }
    } @catch (NSException *e) {
        MKLog(@"方向修正失败: %@", e.reason);
    }
    return img;
}

// 用 ImageIO 降采样读文件，顺便应用 EXIF 方向
static UIImage *MKDownsampleFile(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) {
        MKLog(@"ImageIO 打不开: %@", path);
        return nil;
    }
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform   : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize          : @(MK_MAX_PIXEL),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) {
        MKLog(@"降采样失败，回退整图读取: %@", path);
        return [UIImage imageWithContentsOfFile:path];
    }
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    MKLog(@"降采样 %@ → %.0fx%.0f", path.lastPathComponent, img.size.width, img.size.height);
    CGImageRelease(cg);
    return img;
}

// 相册最新一张（降采样版）。同步执行，禁止在主线程调用。
static UIImage *MKLatestAssetImage(void) {
    if (gSwapFetching) return nil;
    gSwapFetching = YES;

    __block UIImage *out = nil;
    @try {
        PHFetchOptions *opt = [PHFetchOptions new];
        opt.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        PHFetchResult<PHAsset *> *res = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:opt];
        PHAsset *asset = res.firstObject;

        if (!asset) {
            MKLog(@"相册取图：没有可用图片（或未授权相册）");
        } else {
            PHImageRequestOptions *ro = [PHImageRequestOptions new];
            ro.synchronous = YES;
            ro.networkAccessAllowed = YES;
            ro.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
            ro.resizeMode = PHImageRequestOptionsResizeModeExact;

            CGSize target = CGSizeMake(MK_MAX_PIXEL, MK_MAX_PIXEL);
            [[PHImageManager defaultManager]
                requestImageForAsset:asset
                          targetSize:target
                         contentMode:PHImageContentModeAspectFit
                             options:ro
                       resultHandler:^(UIImage *img, NSDictionary *info) {
                out = img;
                MKLog(@"相册取图 %@ → %@ (info=%@)",
                      asset.localIdentifier,
                      img ? [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height] : @"nil",
                      info[PHImageResultIsDegradedKey] ? @"degraded" : @"final");
            }];
        }
    } @catch (NSException *e) {
        MKLog(@"相册取图异常: %@", e.reason);
    }

    gSwapFetching = NO;
    return MKNormalizeUIImage(out);
}

// 读替换图。allowFetch=NO 时只用缓存，绝不在相机线程上碰相册。
static UIImage *MKLoadSwapImage(BOOL force, BOOL allowFetch) {
    MKFakeCfg *c = CFG();
    NSString *key = c.imgPath.length ? c.imgPath : @"@latest";

    if (!force && gSwapImg && [gSwapKey isEqualToString:key] &&
        (CFAbsoluteTimeGetCurrent() - gSwapLoadedAt) < 20.0) {
        return gSwapImg;
    }

    UIImage *img = nil;

    if ([key isEqualToString:@"@latest"]) {
        if ([NSThread isMainThread] || !allowFetch) {
            if (CFAbsoluteTimeGetCurrent() - gSwapLoadedAt > 5.0) {
                MKLOG_ONCE(@"@latest 需要后台取图，已排队预取（本张可能仍是旧图）");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    UIImage *i = MKLatestAssetImage();
                    if (i) { gSwapImg = i; gSwapKey = @"@latest"; gSwapLoadedAt = CFAbsoluteTimeGetCurrent(); }
                });
            }
            return gSwapImg;
        }
        img = MKLatestAssetImage();
    } else {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:key]) {
            img = MKDownsampleFile(key);
            if (!img) MKLog(@"文件存在但解码失败: %@", key);
        } else {
            MKLog(@"换图文件不存在: %@", key);
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *alt = [doc stringByAppendingPathComponent:key.lastPathComponent];
            if (key.lastPathComponent.length && [fm fileExistsAtPath:alt]) {
                MKLog(@"改从沙盒 Documents 读取: %@", alt);
                key = alt;
                img = MKDownsampleFile(alt);
            }
        }
    }

    if (!img) {
        MKLog(@"换图加载失败 key=%@ （继续用旧图：%@）", key, gSwapImg ? @"有" : @"无");
        return gSwapImg;
    }

    gSwapImg = img;
    gSwapKey = key;
    gSwapLoadedAt = CFAbsoluteTimeGetCurrent();
    MKLog(@"换图已载入 %@  %.0fx%.0f scale=%.1f orientation=%ld",
          key, img.size.width, img.size.height, img.scale, (long)img.imageOrientation);
    return gSwapImg;
}

static void MKPrefetchSwapImage(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MKLoadSwapImage(YES, YES);
    });
}

static BOOL MKPhotoArmed(void) {
    MKFakeCfg *c = CFG();
    if (!c.photoOn) return NO;
    if (c.photoAlways) return YES;
    if (c.photoUntil <= 0) return NO;
    return MKUnixNow() < c.photoUntil;
}

// =============================================================================
//  MARK: - 换图：绘制
// =============================================================================

static CVPixelBufferRef gLastPB = NULL;
static double gLastToken = -1;
static CFAbsoluteTime gLastSwapAt = 0;

static void MKDrawCGImage(CGContextRef ctx, CGImageRef cg, size_t w, size_t h) {
    CGFloat iw = (CGFloat)CGImageGetWidth(cg);
    CGFloat ih = (CGFloat)CGImageGetHeight(cg);
    if (iw <= 0 || ih <= 0) return;

    CGFloat s  = CFG().fill ? MAX((CGFloat)w / iw, (CGFloat)h / ih)
                            : MIN((CGFloat)w / iw, (CGFloat)h / ih);
    CGFloat dw = iw * s, dh = ih * s;
    CGFloat dx = ((CGFloat)w - dw) * 0.5f;
    CGFloat dy = ((CGFloat)h - dh) * 0.5f;

    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    CGContextSaveGState(ctx);
    if (CFG().flipY) {
        // CG 原点在左下，像素缓冲行 0 在顶部
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextDrawImage(ctx, CGRectMake(dx, dy, dw, dh), cg);
    CGContextRestoreGState(ctx);
}

// BGRA：拿到裸指针直接画进去，指针/尺寸/bpr/格式全不变
static BOOL MKDrawIntoBGRA(CVPixelBufferRef pb, CGImageRef cg, size_t w, size_t h) {
    CVReturn rc = CVPixelBufferLockBaseAddress(pb, 0);
    if (rc != kCVReturnSuccess) {
        MKLog(@"BGRA 分支：LockBaseAddress 失败 rc=%d", rc);
        return NO;
    }

    BOOL ok = NO;
    void  *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr  = CVPixelBufferGetBytesPerRow(pb);

    if (!base) {
        MKLog(@"BGRA 分支：基址为空（buffer 不可 CPU 写）");
    } else if (bpr < w * 4) {
        MKLog(@"BGRA 分支：bytesPerRow=%zu < w*4=%zu，放弃", bpr, w * 4);
    } else {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        // kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst == 0x2006
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        if (ctx) {
            MKDrawCGImage(ctx, cg, w, h);
            CGContextRelease(ctx);
            ok = YES;
        } else {
            MKLog(@"BGRA 分支：CGBitmapContextCreate 返回 NULL (w=%zu h=%zu bpr=%zu)", w, h, bpr);
        }
        CGColorSpaceRelease(cs);
    }

    CVPixelBufferUnlockBaseAddress(pb, 0);
    return ok;
}

// YUV / 未知格式：CoreImage 直接渲染进目标缓冲
static BOOL MKDrawIntoCI(CVPixelBufferRef pb, CGImageRef cg, size_t w, size_t h) {
    @autoreleasepool {
        CIImage *src = [CIImage imageWithCGImage:cg];
        if (!src) { MKLog(@"CI 分支：CIImage 创建失败"); return NO; }

        CGRect ext = src.extent;
        if (ext.size.width <= 0 || ext.size.height <= 0) {
            MKLog(@"CI 分支：extent 异常 %.0fx%.0f", ext.size.width, ext.size.height);
            return NO;
        }

        CGFloat s = CFG().fill ? MAX((CGFloat)w / ext.size.width, (CGFloat)h / ext.size.height)
                               : MIN((CGFloat)w / ext.size.width, (CGFloat)h / ext.size.height);
        CIImage *scaled = [src imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];

        CGRect se = scaled.extent;
        CGAffineTransform tr = CGAffineTransformMakeTranslation(
            ((CGFloat)w - se.size.width)  * 0.5f - se.origin.x,
            ((CGFloat)h - se.size.height) * 0.5f - se.origin.y);
        CIImage *pos = [scaled imageByApplyingTransform:tr];

        // 白底，避免留白区透明
        CIImage *bg = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]]
                       imageByCroppingToRect:CGRectMake(0, 0, w, h)];
        CIImage *out = [pos imageByCompositingOverImage:bg];

        BOOL soft = (CVPixelBufferGetIOSurface(pb) == NULL);
        CIContext *ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer : @(soft) }];
        if (!ctx) { MKLog(@"CI 分支：CIContext 创建失败"); return NO; }

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        @try {
            CGRect r = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
            [ctx render:out toCVPixelBuffer:pb bounds:r colorSpace:cs];
        } @catch (NSException *e) {
            MKLog(@"CI 分支：render 异常 %@", e.reason);
            CGColorSpaceRelease(cs);
            return NO;
        }
        CGColorSpaceRelease(cs);

        MKLog(@"CI 分支：渲染完成 %zu×%zu fmt=%@ soft=%d",
              w, h, MKFourCC(CVPixelBufferGetPixelFormatType(pb)), soft);
        return YES;
    }
}

// 统一入口：先看四字符码再分派。token 用来区分同一块 buffer 上的不同帧
// （GLFrameBuffer 会复用同一块像素缓冲，只按指针去重会漏掉连拍第二张）
static BOOL MKSwapPixelBuffer(CVPixelBufferRef pb, double token, const char *who) {
    if (!pb) return NO;

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSString *tag = [NSString stringWithUTF8String:who];

    if (pb == gLastPB && token == gLastToken && (t0 - gLastSwapAt) < 3.0) {
        MKLog(@"[%@] 同一帧已处理过（pb=%p token=%.3f），跳过", tag, pb, token);
        return YES;
    }

    UIImage *img = MKLoadSwapImage(NO, NO);
    if (!img) {
        MKLog(@"[%@] 没有可用替换图（路径=%@）", tag, CFG().imgPath);
        return NO;
    }
    CGImageRef cg = img.CGImage;         // 生命周期由 img 持有
    if (!cg) { MKLog(@"[%@] CGImage 为空", tag); return NO; }

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (!w || !h) { MKLog(@"[%@] 缓冲尺寸为 0", tag); return NO; }

    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    BOOL planar = CVPixelBufferIsPlanar(pb);

    MKLog(@"[%@] pb=%p %zu×%zu fmt=%@ bpr=%zu planar=%d iosurface=%p attachments=%p",
          tag, pb, w, h, MKFourCC(fmt), bpr, planar,
          (void *)CVPixelBufferGetIOSurface(pb), MKBufferAttachments(pb));

    BOOL ok = NO;
    if (MKIs32RGBA(fmt)) {
        ok = MKDrawIntoBGRA(pb, cg, w, h);
        if (!ok) {
            MKLog(@"[%@] BGRA 直写失败 → 退回 CoreImage", tag);
            ok = MKDrawIntoCI(pb, cg, w, h);
        }
    } else if (MKIsYUV(fmt)) {
        MKLog(@"[%@] 双平面 YUV，走 CoreImage", tag);
        ok = MKDrawIntoCI(pb, cg, w, h);
    } else {
        MKLog(@"[%@] 未识别格式 %@ → 试 CoreImage", tag, MKFourCC(fmt));
        ok = MKDrawIntoCI(pb, cg, w, h);
    }

    if (ok) { gLastPB = pb; gLastToken = token; gLastSwapAt = t0; }

    MKLog(@"[%@] 换图%@  用时 %.2fms", tag, ok ? @"成功" : @"失败",
          (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    return ok;
}

// =============================================================================
//  MARK: - 相机 hook
// =============================================================================

static IMP o_vsInit  = NULL;   // -[GLVideoSample initWithPixelBuffer:timeStamp:]
static IMP o_photoCb = NULL;   // -[GLVideoDevice captureOutput:didFinishProcessingPhoto:error:]

// 第一层（推荐）：渲染管线入口，buffer 为 BGRA、可写，之后才接滤镜/水印/编码
static id h_vsInit(id self, SEL _cmd, CVPixelBufferRef pb, double ts) {
    if (MKPhotoArmed()) {
        @try { MKSwapPixelBuffer(pb, ts, "GLVideoSample"); }
        @catch (NSException *e) { MKLog(@"h_vsInit 异常: %@", e.reason); }
    }
    return ((id (*)(id, SEL, CVPixelBufferRef, double))o_vsInit)(self, _cmd, pb, ts);
}

// 第二层：AVCapturePhoto 原始帧（'420f' 双平面 YUV），layer=2 时才启用
static void h_photoCb(id self, SEL _cmd, id output, id photo, id error) {
    if (CFG().layer != 1 && MKPhotoArmed()) {
        @try {
            AVCapturePhoto *p = (AVCapturePhoto *)photo;
            CVPixelBufferRef pb = [p pixelBuffer];
            double ts = CMTimeGetSeconds(p.timestamp);
            if (pb) MKSwapPixelBuffer(pb, ts, "AVCapturePhoto");
            else    MKLog(@"AVCapturePhoto.pixelBuffer 为空（settings 未请求像素格式）");
        } @catch (NSException *e) {
            MKLog(@"h_photoCb 异常: %@", e.reason);
        }
    }
    ((void (*)(id, SEL, id, id, id))o_photoCb)(self, _cmd, output, photo, error);
}

static void MKInstallCameraHooks(void) {
    Class vs = objc_getClass("GLVideoSample");
    if (vs) {
        Method m = class_getInstanceMethod(vs, MKSEL(initWithPixelBuffer:timeStamp:));
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            MKLog(@"GLVideoSample initWithPixelBuffer:timeStamp: 返回类型=%c  参数=%s",
                  MKRetType(m), enc ? enc : "?");
            o_vsInit = MKHook(vs, MKSEL(initWithPixelBuffer:timeStamp:), (IMP)h_vsInit,
                              "-[GLVideoSample initWithPixelBuffer:timeStamp:]");
        } else {
            MKLog(@"✗ GLVideoSample 缺 initWithPixelBuffer:timeStamp:");
        }
    } else {
        MKLog(@"✗ GLVideoSample 未加载（GLCameraSDK 尚未 dlopen）");
    }

    Class vd = objc_getClass("GLVideoDevice");
    if (vd) {
        o_photoCb = MKHook(vd, MKSEL(captureOutput:didFinishProcessingPhoto:error:), (IMP)h_photoCb,
                           "-[GLVideoDevice captureOutput:didFinishProcessingPhoto:error:]");
    } else {
        MKLog(@"✗ GLVideoDevice 未加载");
    }
}

// =============================================================================
//  MARK: - 定位 hook
// =============================================================================

static CLLocation *gFakeLoc = nil;
static double gFakeLat = -9999, gFakeLng = -9999;

static CLLocation *MKFakeLocation(void) {
    MKFakeCfg *c = CFG();
    if (gFakeLoc && fabs(gFakeLat - c.lat) < 1e-9 && fabs(gFakeLng - c.lng) < 1e-9) {
        return gFakeLoc;
    }
    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(c.lat, c.lng)
                  altitude:50.0
        horizontalAccuracy:5.0
          verticalAccuracy:5.0
                 timestamp:[NSDate date]];
    gFakeLoc = loc;
    gFakeLat = c.lat;
    gFakeLng = c.lng;
    MKLog(@"构造假 CLLocation %.6f,%.6f alt=50 hAcc=5 vAcc=5", c.lat, c.lng);
    return gFakeLoc;
}

static void MKSpoofModel(id model) {
    if (!model || !CFG().locOn) return;
    NSString *cls = NSStringFromClass([model class]);

    @try {
        [model setValue:@(CFG().lat) forKey:@"latitude"];
        [model setValue:@(CFG().lng) forKey:@"longitude"];
    } @catch (NSException *e) {
        MKLog(@"✗ %@ 经纬度写入失败: %@", cls, e.reason);
        return;
    }

    if (CFG().addr.length) {
        @try {
            if ([model respondsToSelector:MKSEL(setAddress:)]) {
                [model setValue:CFG().addr forKey:@"address"];
            } else if ([model respondsToSelector:MKSEL(setNowAllAddress:)]) {
                [model setValue:CFG().addr forKey:@"nowAllAddress"];
            }
        } @catch (NSException *e) {
            MKLog(@"· %@ 地址写入失败（忽略）: %@", cls, e.reason);
        }
    }
    MKLOG_ONCE(@"模型伪造样例: %@ → %.6f,%.6f", cls, CFG().lat, CFG().lng);
}

static IMP o_mgrGetRecent = NULL, o_mgrSetRecent = NULL, o_mgrCheckAuth = NULL;
static IMP o_infoLat = NULL, o_infoLng = NULL, o_objLat = NULL, o_objLng = NULL;
static IMP o_locMgrLocation = NULL, o_locCoord = NULL, o_locSource = NULL;

static id h_mgrGetRecent(id self, SEL _cmd) {
    id r = ((id (*)(id, SEL))o_mgrGetRecent)(self, _cmd);
    if (!CFG().locOn) return r;

    if (!r) {
        Class c = objc_getClass("MKLocationInfo");
        if (c) {
            id m = [[c alloc] init];
            MKSpoofModel(m);
            MKLOG_ONCE(@"getRecentLocation=nil → 注入一个 MKLocationInfo");
            return m;
        }
        return nil;
    }
    MKSpoofModel(r);
    return r;
}

static void h_mgrSetRecent(id self, SEL _cmd, id v) {
    MKSpoofModel(v);
    ((void (*)(id, SEL, id))o_mgrSetRecent)(self, _cmd, v);
}

static BOOL h_mgrCheckAuth(id self, SEL _cmd) {
    if (CFG().locOn) return YES;
    return ((BOOL (*)(id, SEL))o_mgrCheckAuth)(self, _cmd);
}

static double h_infoLat(id self, SEL _cmd) {
    return CFG().locOn ? CFG().lat : ((double (*)(id, SEL))o_infoLat)(self, _cmd);
}
static double h_infoLng(id self, SEL _cmd) {
    return CFG().locOn ? CFG().lng : ((double (*)(id, SEL))o_infoLng)(self, _cmd);
}
static double h_objLat(id self, SEL _cmd) {
    return CFG().locOn ? CFG().lat : ((double (*)(id, SEL))o_objLat)(self, _cmd);
}
static double h_objLng(id self, SEL _cmd) {
    return CFG().locOn ? CFG().lng : ((double (*)(id, SEL))o_objLng)(self, _cmd);
}

static id h_locMgrLocation(id self, SEL _cmd) {
    if (CFG().locOn) {
        CLLocation *f = MKFakeLocation();
        if (f) return f;
    }
    return ((id (*)(id, SEL))o_locMgrLocation)(self, _cmd);
}

static CLLocationCoordinate2D h_locCoord(id self, SEL _cmd) {
    if (CFG().locOn) return CLLocationCoordinate2DMake(CFG().lat, CFG().lng);
    return ((CLLocationCoordinate2D (*)(id, SEL))o_locCoord)(self, _cmd);
}

static id h_locSource(id self, SEL _cmd) {
    if (CFG().antiOn && CFG().locOn) return nil;    // 整个 sourceInformation 抹掉
    return ((id (*)(id, SEL))o_locSource)(self, _cmd);
}

// 只在返回类型确实是 double 时才挂，避免 ABI 错位导致崩溃
static void MKHookDoubleGetter(Class cls, SEL sel, IMP fn, IMP *slot, const char *label) {
    if (!cls) { MKLog(@"✗ %s：类不存在", label); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m)   { MKLog(@"✗ %s：方法不存在", label); return; }
    char rt = MKRetType(m);
    if (rt != 'd') { MKLog(@"✗ %s：返回类型 %c≠d，跳过（防崩）", label, rt); return; }
    *slot = MKHook(cls, sel, fn, label);
}

static void MKInstallLocationHooks(void) {
    Class mgr = objc_getClass("MKLocationManager");
    if (mgr) {
        o_mgrGetRecent = MKHook(mgr, MKSEL(getRecentLocation), (IMP)h_mgrGetRecent,
                                "-[MKLocationManager getRecentLocation]");
        o_mgrSetRecent = MKHook(mgr, MKSEL(setRecentLocation:), (IMP)h_mgrSetRecent,
                                "-[MKLocationManager setRecentLocation:]");
        o_mgrCheckAuth = MKHook(mgr, MKSEL(checkLocationAuthorization), (IMP)h_mgrCheckAuth,
                                "-[MKLocationManager checkLocationAuthorization]");
    } else {
        MKLog(@"✗ MKLocationManager 不存在");
    }

    MKHookDoubleGetter(objc_getClass("MKLocationInfo"), MKSEL(latitude),
                       (IMP)h_infoLat, &o_infoLat, "-[MKLocationInfo latitude]");
    MKHookDoubleGetter(objc_getClass("MKLocationInfo"), MKSEL(longitude),
                       (IMP)h_infoLng, &o_infoLng, "-[MKLocationInfo longitude]");

    Class obj = objc_getClass("_TtC8marki_cn16MKLocationObject");
    MKHookDoubleGetter(obj, MKSEL(latitude), (IMP)h_objLat, &o_objLat, "-[MKLocationObject latitude]");
    MKHookDoubleGetter(obj, MKSEL(longitude), (IMP)h_objLng, &o_objLng, "-[MKLocationObject longitude]");

    o_locMgrLocation = MKHook(objc_getClass("CLLocationManager"), @selector(location),
                              (IMP)h_locMgrLocation, "-[CLLocationManager location]");
    o_locCoord = MKHook(objc_getClass("CLLocation"), @selector(coordinate),
                        (IMP)h_locCoord, "-[CLLocation coordinate]");
    o_locSource = MKHook(objc_getClass("CLLocation"), @selector(sourceInformation),
                         (IMP)h_locSource, "-[CLLocation sourceInformation]");
}

// =============================================================================
//  MARK: - 反作弊归零
//
//  ① -[CLLocationSourceInformation isSimulatedBySoftware]   iOS15+ 系统模拟定位标记
//  ② -[CLLocation sourceInformation]                        同上，整对象抹成 nil
//  ③ -[BMKLocation mockProbability]                          百度：单点概率 (int)
//  ④ -[BMKLocationManager getMockLocationProbability]        百度：管理器概率 (int)
//  ⑤ -[TNKLocation mockGPS]                                  腾讯：mock 标记 (BOOL)
//  ⑥ -[BusinessConfigCenter mockLimitProbability]            服务端阈值 (long long) → 100
//  ⑦ -[LocationRealManager isMockLocation]                   App 自己的开关
//  ⑧ -[CLLocation distanceFromLocation:]                     可选：抹掉"位移>200m"判定
// =============================================================================

static IMP o_simSoftware = NULL, o_bmkMockProb = NULL, o_bmkMgrMockProb = NULL;
static IMP o_tnkMockGPS = NULL, o_bizMockLimit = NULL, o_realIsMock = NULL, o_distance = NULL;

static BOOL h_simSoftware(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"① isSimulatedBySoftware → NO"); return NO; }
    return ((BOOL (*)(id, SEL))o_simSoftware)(self, _cmd);
}
static int h_bmkMockProb(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"③ BMKLocation.mockProbability → 0"); return 0; }
    return ((int (*)(id, SEL))o_bmkMockProb)(self, _cmd);
}
static int h_bmkMgrMockProb(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"④ BMKLocationManager.getMockLocationProbability → 0"); return 0; }
    return ((int (*)(id, SEL))o_bmkMgrMockProb)(self, _cmd);
}
static BOOL h_tnkMockGPS(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"⑤ TNKLocation.mockGPS → NO"); return NO; }
    return ((BOOL (*)(id, SEL))o_tnkMockGPS)(self, _cmd);
}
static long long h_bizMockLimit(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"⑥ BusinessConfigCenter.mockLimitProbability → 100"); return 100; }
    return ((long long (*)(id, SEL))o_bizMockLimit)(self, _cmd);
}
static BOOL h_realIsMock(id self, SEL _cmd) {
    if (CFG().antiOn) { MKLOG_ONCE(@"⑦ LocationRealManager.isMockLocation → NO"); return NO; }
    return ((BOOL (*)(id, SEL))o_realIsMock)(self, _cmd);
}
static double h_distance(id self, SEL _cmd, CLLocation *other) {
    if (CFG().antiOn && CFG().locOn) { MKLOG_ONCE(@"⑧ distanceFromLocation: → 0"); return 0.0; }
    return ((double (*)(id, SEL, id))o_distance)(self, _cmd, other);
}

static void MKInstallAntiCheatHooks(void) {
    o_simSoftware = MKHook(objc_getClass("CLLocationSourceInformation"),
                           @selector(isSimulatedBySoftware), (IMP)h_simSoftware,
                           "-[CLLocationSourceInformation isSimulatedBySoftware]");
    o_bmkMockProb = MKHook(objc_getClass("BMKLocation"),
                           MKSEL(mockProbability), (IMP)h_bmkMockProb,
                           "-[BMKLocation mockProbability]");
    o_bmkMgrMockProb = MKHook(objc_getClass("BMKLocationManager"),
                              MKSEL(getMockLocationProbability), (IMP)h_bmkMgrMockProb,
                              "-[BMKLocationManager getMockLocationProbability]");
    o_tnkMockGPS = MKHook(objc_getClass("TNKLocation"),
                          MKSEL(mockGPS), (IMP)h_tnkMockGPS,
                          "-[TNKLocation mockGPS]");
    o_bizMockLimit = MKHook(objc_getClass("BusinessConfigCenter"),
                            MKSEL(mockLimitProbability), (IMP)h_bizMockLimit,
                            "-[BusinessConfigCenter mockLimitProbability]");
    o_realIsMock = MKHook(objc_getClass("_TtC8marki_cn19LocationRealManager"),
                          MKSEL(isMockLocation), (IMP)h_realIsMock,
                          "-[LocationRealManager isMockLocation]");
    o_distance = MKHook(objc_getClass("CLLocation"), @selector(distanceFromLocation:),
                        (IMP)h_distance, "-[CLLocation distanceFromLocation:]");
}

// =============================================================================
//  MARK: - 时间基准（C 层）—— 水印时间的真正来源
//
//  逆向结论（GPUMarkSDK 导入符号）：
//    _time  _gettimeofday  _clock_gettime  _localtime  _gmtime  _strftime  _mktime
//    _ZNSt3__16chrono12system_clock3nowEv / to_time_t / from_time_t
//    _ZN4mark16DateTimeProvider*  _ZN4mark18DateTimeDataSource7convert*
//  → 水印的时间戳是渲染 SDK 里用 C++ 的 system_clock + strftime 算出来的，
//    全程不碰 NSDateFormatter，所以 hook NSDateFormatter 对水印无效。
//  对策：用 dyld 的 __interpose 段直接换掉 time/gettimeofday/clock_gettime，
//        偏移方式（real + delta），保持时间单调递增，不冻结。
// =============================================================================

static NSDate *MKParseFakeTime(NSString *s);   // 定义在「拍摄时间」段
static time_t gTimeDelta = 0;        // 秒，正数=未来
static BOOL   gTimeShiftOn = NO;

static time_t (*mk_orig_time)(time_t *) = NULL;
static int    (*mk_orig_gettimeofday)(struct timeval *, void *) = NULL;
static int    (*mk_orig_clock_gettime)(clockid_t, struct timespec *) = NULL;

static void MKResolveRealClockFns(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mk_orig_time          = (time_t (*)(time_t *))dlsym(RTLD_NEXT, "time");
        mk_orig_gettimeofday  = (int (*)(struct timeval *, void *))dlsym(RTLD_NEXT, "gettimeofday");
        mk_orig_clock_gettime = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_NEXT, "clock_gettime");
        MKLog(@"时钟 interpose 就绪 time=%p gettimeofday=%p clock_gettime=%p",
              mk_orig_time, mk_orig_gettimeofday, mk_orig_clock_gettime);
    });
}

static time_t MK_time(time_t *out) {
    MKResolveRealClockFns();
    time_t real = mk_orig_time ? mk_orig_time(NULL) : 0;
    time_t v = (gTimeShiftOn && gTimeDelta) ? (real + gTimeDelta) : real;
    if (out) *out = v;
    return v;
}

static int MK_gettimeofday(struct timeval *tv, void *tz) {
    MKResolveRealClockFns();
    int rc = mk_orig_gettimeofday ? mk_orig_gettimeofday(tv, tz) : -1;
    if (rc == 0 && tv && gTimeShiftOn && gTimeDelta) tv->tv_sec += gTimeDelta;
    return rc;
}

static int MK_clock_gettime(clockid_t cid, struct timespec *ts) {
    MKResolveRealClockFns();
    int rc = mk_orig_clock_gettime ? mk_orig_clock_gettime(cid, ts) : -1;
    // 只动 CLOCK_REALTIME；MONOTONIC / UPTIME_RAW 必须保持真实，否则定时器全乱
    if (rc == 0 && ts && cid == CLOCK_REALTIME && gTimeShiftOn && gTimeDelta) {
        ts->tv_sec += gTimeDelta;
    }
    return rc;
}

#define MK_INTERPOSE(repl, orig) \
    { (const void *)(repl), (const void *)(orig) }

__attribute__((used, section("__DATA,__interpose")))
static const void *mk_clock_interpose[] = {
    MK_INTERPOSE(MK_time, time),
    MK_INTERPOSE(MK_gettimeofday, gettimeofday),
    MK_INTERPOSE(MK_clock_gettime, clock_gettime),
};

// 把 cfg.fakeTime 换算成 delta（相对当前真实时间）
static void MKRecomputeTimeDelta(void) {
    MKFakeCfg *c = CFG();
    NSDate *fake = MKParseFakeTime(c.fakeTime);
    if (!fake) { gTimeDelta = 0; gTimeShiftOn = NO; return; }
    MKResolveRealClockFns();
    time_t real = mk_orig_time ? mk_orig_time(NULL) : (time_t)[NSDate date].timeIntervalSince1970;
    gTimeDelta = (time_t)llround([fake timeIntervalSince1970] - (double)real);
    gTimeShiftOn = c.timeOn;
    MKLog(@"时钟偏移 delta=%lld 秒 (%.1f 天)，开关=%d",
          (long long)gTimeDelta, (double)gTimeDelta / 86400.0, (int)gTimeShiftOn);
}

// =============================================================================
//  MARK: - 拍摄时间
// =============================================================================

static IMP o_stringFromDate = NULL;
static IMP o_dateNow = NULL;
static NSDate *gFakeDate = nil;

static NSArray<NSString *> *MKTimeFormats(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"yyyy-MM-dd HH:mm",     @"yyyy-MM-dd HH:mm:ss",
              @"yyyy年MM月dd日",         @"yyyy/MM/dd HH:mm",
              @"yyyy/MM/dd HH:mm:ss",   @"yyyy-MM-dd",
              @"HH:mm",                 @"HH:mm:ss",
              @"MM-dd HH:mm",           @"yyyyMMdd HHmmss"];
    });
    return a;
}

// 手动解析，绕开 NSDateFormatter（否则会递归进自己的 hook）
static NSDate *MKParseFakeTime(NSString *s) {
    if (s.length < 16) return nil;
    int Y = 0, M = 0, D = 0, h = 0, m = 0, sec = 0;
    int n = sscanf(s.UTF8String, "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &sec);
    if (n < 5) {
        MKLog(@"假时间格式不对: %@（要 yyyy-MM-dd HH:mm[:ss]）", s);
        return nil;
    }
    NSDateComponents *c = [NSDateComponents new];
    c.year = Y; c.month = M; c.day = D;
    c.hour = h; c.minute = m; c.second = sec;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"] ?: [NSTimeZone localTimeZone];
    return [cal dateFromComponents:c];
}

static void MKRefreshFakeDate(void) {
    gFakeDate = MKParseFakeTime(CFG().fakeTime);
    MKLog(@"假时间 \"%@\" → NSDate=%@", CFG().fakeTime, gFakeDate);
    MKRecomputeTimeDelta();          // 同步 C 层时钟偏移
}

static id h_stringFromDate(id self, SEL _cmd, NSDate *date) {
    if (!CFG().timeOn || !gFakeDate) {
        return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
    }
    NSString *fmt = nil;
    @try { fmt = [(NSDateFormatter *)self dateFormat]; } @catch (NSException *e) { fmt = nil; }

    if (!fmt || [MKTimeFormats() containsObject:fmt]) {
        MKLOG_ONCE(@"时间替换 dateFormat=%@ → %@", fmt, CFG().fakeTime);
        // 用原 IMP 调，绝不递归
        return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, gFakeDate);
    }
    return ((id (*)(id, SEL, id))o_stringFromDate)(self, _cmd, date);
}

static id h_dateNow(id self, SEL _cmd) {
    if (CFG().timeOn && gFakeDate) { MKLOG_ONCE(@"+[NSDate now] 已替换"); return gFakeDate; }
    return ((id (*)(id, SEL))o_dateNow)(self, _cmd);
}

// +[NSDate date]：用偏移，不返回恒定值 —— 否则签名/证书/HTTP Date 会全线失效
static IMP o_dateNowClass = NULL;
static id h_dateDate(id self, SEL _cmd) {
    id real = ((id (*)(id, SEL))o_dateNowClass)(self, _cmd);
    if (!CFG().timeOn || !gTimeShiftOn || gTimeDelta == 0) return real;
    MKLOG_ONCE(@"+[NSDate date] 已按 delta 偏移");
    return [real dateByAddingTimeInterval:(NSTimeInterval)gTimeDelta];
}

static void MKInstallTimeHooks(void) {
    MKRefreshFakeDate();
    o_stringFromDate = MKHook(objc_getClass("NSDateFormatter"), @selector(stringFromDate:),
                              (IMP)h_stringFromDate, "-[NSDateFormatter stringFromDate:]");
    o_dateNow = MKHookClass(objc_getClass("NSDate"), @selector(now), (IMP)h_dateNow, "+[NSDate now]");
    o_dateNowClass = MKHookClass(objc_getClass("NSDate"), @selector(date), (IMP)h_dateDate, "+[NSDate date]");
}

// =============================================================================
//  MARK: - 天气
// =============================================================================

static IMP o_setCondTxt = NULL, o_setTemperature = NULL;
static IMP o_getCondTxt = NULL, o_getTemperature = NULL;

static void h_setCondTxt(id self, SEL _cmd, NSString *v) {
    if (CFG().wxOn) { MKLOG_ONCE(@"天气 condTxt → %@", CFG().wxText); v = CFG().wxText; }
    ((void (*)(id, SEL, id))o_setCondTxt)(self, _cmd, v);
}
static void h_setTemperature(id self, SEL _cmd, long long v) {
    if (CFG().wxOn) { MKLOG_ONCE(@"天气 temperature → %lld", CFG().wxTemp); v = CFG().wxTemp; }
    ((void (*)(id, SEL, long long))o_setTemperature)(self, _cmd, v);
}
static id h_getCondTxt(id self, SEL _cmd) {
    if (CFG().wxOn) return CFG().wxText;
    return ((id (*)(id, SEL))o_getCondTxt)(self, _cmd);
}
static long long h_getTemperature(id self, SEL _cmd) {
    if (CFG().wxOn) return CFG().wxTemp;
    return ((long long (*)(id, SEL))o_getTemperature)(self, _cmd);
}

// ---- 天气：引擎入口拦截 ----
//  GPUMarkSDK 里有 mark::WeatherProvider : BaseValueProvider<mark::Weather>
//  （导入符号 _ZN4mark15WeatherProviderE / ValueObserverINS_7WeatherEE），
//  说明天气是宿主把字符串「推」进渲染引擎的，不是在渲染时读 MKWeatherInfo。
//  所以在推送点做文本替换，比改模型 getter 更可靠。

static IMP o_gmUpdateItem = NULL;
static IMP o_gmGetContent = NULL;

static BOOL MKLooksLikeWeather(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length == 0 || s.length > 24) return NO;
    if ([s containsString:@"℃"] || [s containsString:@"°"]) return YES;
    NSArray *kw = @[@"晴", @"多云", @"阴", @"小雨", @"中雨", @"大雨", @"暴雨", @"阵雨",
                    @"雷阵雨", @"雪", @"雾", @"霾", @"沙尘", @"大风", @"微风", @"空气质量"];
    for (NSString *k in kw) if ([s containsString:k]) return YES;
    return NO;
}

static NSString *MKFakeWeatherText(NSString *orig) {
    MKFakeCfg *c = CFG();
    if (!c.wxText.length) return orig;
    // 保留原串里的温度符号风格，尽量不破坏模板排版
    if ([orig containsString:@"°"] || [orig containsString:@"℃"]) {
        return [NSString stringWithFormat:@"%@ %lld°", c.wxText, c.wxTemp];
    }
    return c.wxText;
}

// -[GMWatermarkItemCallback updateItemWithId:withContent:]  v28@0:8i16@20
static void h_gmUpdateItem(id self, SEL _cmd, int itemId, id content) {
    if (CFG().wxOn && MKLooksLikeWeather(content)) {
        NSString *fake = MKFakeWeatherText(content);
        MKLog(@"天气被引擎取用 itemId=%d 原=%@ → 新=%@", itemId, content, fake);
        content = fake;
    }
    ((void (*)(id, SEL, int, id))o_gmUpdateItem)(self, _cmd, itemId, content);
}

// -[GPUMarkImageFilter getWatermarkItemContentWithId:]  只观测，确认 id 分布
static id h_gmGetContent(id self, SEL _cmd, int itemId) {
    id r = ((id (*)(id, SEL, int))o_gmGetContent)(self, _cmd, itemId);
    if (MKLooksLikeWeather(r)) {
        MKLog(@"引擎回读水印条目 itemId=%d content=%@", itemId, r);
        if (CFG().wxOn) return MKFakeWeatherText(r);
    }
    return r;
}

static void MKInstallWeatherHooks(void) {
    // ① 引擎推送点
    o_gmUpdateItem = MKHook(objc_getClass("GMWatermarkItemCallback"),
                            MKSEL(updateItemWithId:withContent:), (IMP)h_gmUpdateItem,
                            "-[GMWatermarkItemCallback updateItemWithId:withContent:]");
    o_gmGetContent = MKHook(objc_getClass("GPUMarkImageFilter"),
                            MKSEL(getWatermarkItemContentWithId:), (IMP)h_gmGetContent,
                            "-[GPUMarkImageFilter getWatermarkItemContentWithId:]");

    // ② 模型层（原来的，保留）
    Class w = objc_getClass("MKWeatherInfo");
    if (!w) { MKLog(@"✗ MKWeatherInfo 不存在，天气 hook 跳过"); return; }

    o_setCondTxt = MKHook(w, MKSEL(setCondTxt:), (IMP)h_setCondTxt, "-[MKWeatherInfo setCondTxt:]");
    o_setTemperature = MKHook(w, MKSEL(setTemperature:), (IMP)h_setTemperature,
                              "-[MKWeatherInfo setTemperature:]");

    Method mc = class_getInstanceMethod(w, MKSEL(condTxt));
    if (mc && MKRetType(mc) == '@') {
        o_getCondTxt = MKHook(w, MKSEL(condTxt), (IMP)h_getCondTxt, "-[MKWeatherInfo condTxt]");
    }
    Method mt = class_getInstanceMethod(w, MKSEL(temperature));
    if (mt && (MKRetType(mt) == 'q' || MKRetType(mt) == 'Q')) {
        o_getTemperature = MKHook(w, MKSEL(temperature), (IMP)h_getTemperature,
                                  "-[MKWeatherInfo temperature]");
    }
}

// =============================================================================
//  MARK: - UI
// =============================================================================

#define MKC_RGB(r,g,b)     [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]
#define MKC_RGBA(r,g,b,a)  [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)]

static UIColor *MKC_BG(void)     { return MKC_RGBA(26, 26, 34, 0.95); }
static UIColor *MKC_BOX(void)    { return MKC_RGBA(46, 46, 58, 0.92); }
static UIColor *MKC_TEXT(void)   { return MKC_RGB(242, 242, 247); }
static UIColor *MKC_SUB(void)    { return MKC_RGBA(235, 235, 245, 0.55); }
static UIColor *MKC_GREEN(void)  { return MKC_RGB(48, 209, 88); }
static UIColor *MKC_ORANGE(void) { return MKC_RGB(255, 159, 10); }
static UIColor *MKC_RED(void)    { return MKC_RGB(255, 69, 58); }
static UIColor *MKC_BLUE(void)   { return MKC_RGB(10, 132, 255); }
static UIColor *MKC_PURPLE(void) { return MKC_RGB(191, 90, 242); }
static UIColor *MKC_TEAL(void)   { return MKC_RGB(48, 176, 199); }

static UIWindow *gFABWindow = nil;
static BOOL gPanelShown = NO;
static BOOL gPanelOnScreen = NO;

static UIViewController *MKTopVC(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w == gFABWindow) continue;
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!key) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w == gFABWindow) continue;
            if (w.isKeyWindow) { key = w; break; }
        }
    }
    if (!key) key = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSString *MKLogTail(NSUInteger lines) {
    NSString *s = [NSString stringWithContentsOfFile:MKLogFilePath()
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s.length) return @"（暂无日志）";
    NSArray *arr = [s componentsSeparatedByString:@"\n"];
    if (arr.count <= lines) return s;
    return [[arr subarrayWithRange:NSMakeRange(arr.count - lines, lines)]
            componentsJoinedByString:@"\n"];
}

static NSString *MKLogWhole(void) {
    NSString *s = [NSString stringWithContentsOfFile:MKLogFilePath()
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s.length ? s : @"（暂无日志）";
}

// 底部小提示（深色胶囊，1.8 秒自动消失）
static void MKSnack(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *x in ((UIWindowScene *)sc).windows) {
                    if (x == gFABWindow) continue;
                    if (x.isKeyWindow) { w = x; break; }
                }
                if (w) break;
            }
        }
        if (!w) w = [UIApplication sharedApplication].keyWindow;
        if (!w) return;

        UILabel *l = [UILabel new];
        l.text = text;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.backgroundColor = MKC_RGBA(0, 0, 0, 0.82);
        l.layer.cornerRadius = 12;
        l.layer.masksToBounds = YES;

        CGFloat maxW = w.bounds.size.width - 80;
        CGSize sz = [l sizeThatFits:CGSizeMake(maxW - 28, CGFLOAT_MAX)];
        l.frame = CGRectMake(0, 0, sz.width + 28, sz.height + 18);
        l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height - 110);
        l.alpha = 0;
        [w addSubview:l];

        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.25 delay:1.6 options:0 animations:^{ l.alpha = 0; }
                             completion:^(BOOL d) { [l removeFromSuperview]; }];
        }];
    });
}

static void MKAlert(NSString *title, NSString *msg) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = MKTopVC();
        if (!top) { MKLog(@"提示框失败：无顶层 VC"); return; }
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

// =============================================================================
//  MARK: - 悬浮球
// =============================================================================

@interface MKFABWindow : UIWindow
@end
@implementation MKFABWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static void MKShowPanel(void);

@interface MKFABTarget : NSObject
@end

@implementation MKFABTarget
- (void)mkTap:(id)sender {
    MKLog(@"悬浮球点击 → 打开面板");
    MKShowPanel();
}
- (void)mkPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint p = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static MKFABTarget *gFABTarget = nil;

static void MKInstallFAB(void) {
    if (!CFG().fab) { MKLog(@"悬浮球已在配置里关闭"); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFABWindow) return;

        MKFABWindow *w = [[MKFABWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [UIViewController new];
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    w.windowScene = (UIWindowScene *)sc;
                    break;
                }
            }
        }

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(10, 150, 46, 46);
        b.backgroundColor = MKC_RGBA(0, 0, 0, 0.55);
        b.layer.cornerRadius = 23;
        b.layer.masksToBounds = YES;
        b.layer.borderWidth = 1;
        b.layer.borderColor = MKC_RGBA(255, 255, 255, 0.5).CGColor;
        [b setTitle:@"假" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:19];

        gFABTarget = [MKFABTarget new];
        [b addTarget:gFABTarget action:@selector(mkTap:) forControlEvents:UIControlEventTouchUpInside];
        [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gFABTarget
                                                                       action:@selector(mkPan:)]];

        [w.rootViewController.view addSubview:b];
        w.hidden = NO;
        gFABWindow = w;
        MKLog(@"悬浮球已创建 (10,150)");
    });
}

// =============================================================================
//  MARK: - 时间选择底部弹层
// =============================================================================

@interface MKDatePickerSheet : UIViewController
@property (nonatomic, copy) void (^onDone)(NSDate *date);
@property (nonatomic, strong) NSDate *initialDate;
@end

@implementation MKDatePickerSheet

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MKC_RGBA(0, 0, 0, 0.45);
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;

    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat sheetH = 320;

    UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, H - sheetH, W, sheetH)];
    sheet.backgroundColor = MKC_RGB(38, 38, 46);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:sheet.bounds
                                             byRoundingCorners:(UIRectCornerTopLeft | UIRectCornerTopRight)
                                                   cornerRadii:CGSizeMake(16, 16)];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = bp.CGPath;
    sheet.layer.mask = mask;
    [self.view addSubview:sheet];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, W, 22)];
    t.text = @"选择拍摄时间";
    t.textAlignment = NSTextAlignmentCenter;
    t.textColor = MKC_TEXT();
    t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [sheet addSubview:t];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(8, 6, 64, 30);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelTap) forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:cancel];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(W - 72, 6, 64, 30);
    [done setTitle:@"确定" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [done addTarget:self action:@selector(doneTap) forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:done];

    UIDatePicker *dp = [[UIDatePicker alloc] initWithFrame:CGRectMake(0, 42, W, 260)];
    dp.datePickerMode = UIDatePickerModeDateAndTime;
    dp.preferredDatePickerStyle = UIDatePickerStyleWheels;
    dp.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    dp.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    dp.date = self.initialDate ?: [NSDate date];
    dp.tag = 9001;
    [sheet addSubview:dp];
}

- (void)cancelTap {
    MKLog(@"时间选择：取消");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doneTap {
    UIDatePicker *dp = (UIDatePicker *)[self.view viewWithTag:9001] ?: [self deepFindPicker:self.view];
    NSDate *d = dp ? dp.date : [NSDate date];
    MKLog(@"时间选择：确定 %@", d);
    if (self.onDone) self.onDone(d);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIDatePicker *)deepFindPicker:(UIView *)v {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UIDatePicker class]]) return (UIDatePicker *)s;
        UIDatePicker *r = [self deepFindPicker:s];
        if (r) return r;
    }
    return nil;
}

@end

// 手动格式化，绕开 NSDateFormatter（它已被 hook）
static NSString *MKFormatDateManual(NSDate *d) {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone localTimeZone];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                          NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                                 fromDate:d];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld:%02ld:%02ld",
            (long)c.year, (long)c.month, (long)c.day,
            (long)c.hour, (long)c.minute, (long)c.second];
}

// =============================================================================
//  MARK: - 地图选点
// =============================================================================

// GCJ-02 → WGS-84：高德/苹果地图在国内给的是 GCJ-02，App 上报用的是 WGS-84
static const double MK_PI = 3.1415926535897932384626;
static const double MK_AXIS = 6378245.0;
static const double MK_EE = 0.00669342162296594323;

static BOOL MKOutOfChina(double lat, double lng) {
    return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
}
static double MKTransLat(double x, double y) {
    double r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * MK_PI) + 20.0 * sin(2.0 * x * MK_PI)) * 2.0 / 3.0;
    r += (20.0 * sin(y * MK_PI) + 40.0 * sin(y / 3.0 * MK_PI)) * 2.0 / 3.0;
    r += (160.0 * sin(y / 12.0 * MK_PI) + 320.0 * sin(y * MK_PI / 30.0)) * 2.0 / 3.0;
    return r;
}
static double MKTransLng(double x, double y) {
    double r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x));
    r += (20.0 * sin(6.0 * x * MK_PI) + 20.0 * sin(2.0 * x * MK_PI)) * 2.0 / 3.0;
    r += (20.0 * sin(x * MK_PI) + 40.0 * sin(x / 3.0 * MK_PI)) * 2.0 / 3.0;
    r += (150.0 * sin(x / 12.0 * MK_PI) + 300.0 * sin(x / 30.0 * MK_PI)) * 2.0 / 3.0;
    return r;
}
static CLLocationCoordinate2D MKWGS84FromGCJ02(double lat, double lng) {
    if (MKOutOfChina(lat, lng)) return CLLocationCoordinate2DMake(lat, lng);
    double dLat = MKTransLat(lng - 105.0, lat - 35.0);
    double dLng = MKTransLng(lng - 105.0, lat - 35.0);
    double radLat = lat / 180.0 * MK_PI;
    double magic = sin(radLat);
    magic = 1 - MK_EE * magic * magic;
    double sq = sqrt(magic);
    dLat = (dLat * 180.0) / ((MK_AXIS * (1 - MK_EE)) / (magic * sq) * MK_PI);
    dLng = (dLng * 180.0) / (MK_AXIS / sq * cos(radLat) * MK_PI);
    return CLLocationCoordinate2DMake(lat - dLat, lng - dLng);
}

@interface MKMapPickerViewController : UIViewController <MKMapViewDelegate, CLLocationManagerDelegate>
@property (nonatomic, copy)   void (^onPick)(double lat, double lng, NSString *addr);
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UILabel   *coordLabel;
@property (nonatomic, strong) UILabel   *addrLabel;
@property (nonatomic, strong) UIButton  *okButton;
@property (nonatomic, strong) CLLocationManager *locMgr;
@property (nonatomic, assign) BOOL laidOut;
@property (nonatomic, assign) BOOL resolving;
@end

@implementation MKMapPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.modalPresentationStyle = UIModalPresentationFullScreen;

    _mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    _mapView.delegate = self;
    _mapView.showsCompass = YES;
    _mapView.showsScale = NO;
    [self.view addSubview:_mapView];

    MKFakeCfg *c = CFG();
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake(c.lat, c.lng);
    if (fabs(c.lat) < 1e-6 && fabs(c.lng) < 1e-6) {
        center = CLLocationCoordinate2DMake(39.9042, 116.4074);
    }
    [_mapView setRegion:MKCoordinateRegionMakeWithDistance(center, 1200, 1200) animated:NO];

    [self buildTopBar];
    [self buildPin];
    [self buildInfoBox];
    MKLog(@"地图选点已打开 中心=%.6f,%.6f", center.latitude, center.longitude);
}

- (void)buildTopBar {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)];
    bar.backgroundColor = MKC_RGBA(255, 255, 255, 0.94);
    bar.tag = 7001;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 52, bar.bounds.size.width, 30)];
    title.text = @"选择位置";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [UIColor blackColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:title];

    NSString *lefts[2]  = {@"取消", @"搜索"};
    NSString *rights[2] = {@"定位自己", @"确定"};
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(i == 0 ? 14 : 74, 54, 56, 26);
        [b setTitle:lefts[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16];
        b.tag = 7100 + i;
        [b addTarget:self action:@selector(topBarTap:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        CGFloat w = (i == 0) ? 72 : 48;
        b.frame = CGRectMake(bar.bounds.size.width - 14 - w - (i == 0 ? 58 : 0), 54, w, 26);
        [b setTitle:rights[i] forState:UIControlStateNormal];
        b.titleLabel.font = (i == 1) ? [UIFont boldSystemFontOfSize:16] : [UIFont systemFontOfSize:16];
        b.tag = 7110 + i;
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [b addTarget:self action:@selector(topBarTap:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        if (i == 1) self.okButton = b;
    }
}

- (void)buildPin {
    UIImageView *pin = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
    pin.tag = 7002;
    UIImage *img = [UIImage systemImageNamed:@"mappin.circle.fill"];
    if (img) {
        pin.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        pin.tintColor = [UIColor systemRedColor];
    }
    pin.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:pin];
}

- (void)buildInfoBox {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(12, 0, self.view.bounds.size.width - 24, 64)];
    box.tag = 7003;
    box.backgroundColor = MKC_RGBA(255, 255, 255, 0.93);
    box.layer.cornerRadius = 12;
    box.layer.masksToBounds = YES;
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:box];

    _coordLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, box.bounds.size.width - 24, 20)];
    _coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    _coordLabel.textColor = [UIColor blackColor];
    _coordLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _coordLabel.text = @"地图 GCJ-02 --";
    [box addSubview:_coordLabel];

    _addrLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, box.bounds.size.width - 24, 20)];
    _addrLabel.font = [UIFont systemFontOfSize:12];
    _addrLabel.textColor = MKC_RGB(110, 110, 115);
    _addrLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _addrLabel.text = @"保存 WGS-84 --";
    [box addSubview:_addrLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.laidOut) return;
    self.laidOut = YES;

    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    UIView *bar  = [self.view viewWithTag:7001];
    UIView *pin  = [self.view viewWithTag:7002];
    UIView *box  = [self.view viewWithTag:7003];

    CGFloat barH = 96;
    bar.frame = CGRectMake(0, 0, W, barH);
    self.mapView.frame = CGRectMake(0, barH, W, H - barH);
    if (pin) pin.center = CGPointMake(W / 2, (H + barH) / 2 - 20);
    if (box) box.frame = CGRectMake(12, H - 96, W - 24, 64);
    [self updateCoordLabels];
}

- (void)mapViewDidChangeVisibleRegion:(MKMapView *)mapView {
    [self updateCoordLabels];
}

- (void)updateCoordLabels {
    CLLocationCoordinate2D gcj = self.mapView.centerCoordinate;
    CLLocationCoordinate2D wgs = MKWGS84FromGCJ02(gcj.latitude, gcj.longitude);
    _coordLabel.text = [NSString stringWithFormat:@"地图 GCJ-02 %.6f, %.6f", gcj.latitude, gcj.longitude];
    _addrLabel.text  = [NSString stringWithFormat:@"保存 WGS-84 %.6f, %.6f", wgs.latitude, wgs.longitude];
}

- (void)topBarTap:(UIButton *)b {
    NSInteger t = b.tag;
    if (t == 7100) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    if (t == 7101) { [self doSearch]; return; }
    if (t == 7110) { [self doLocateSelf]; return; }
    if (t == 7111) { [self doConfirm]; return; }
}

- (void)doSearch {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"搜索位置"
                                                               message:@"输入地点、道路、小区或公司名称"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例如：北京西站";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *q = ac.textFields.firstObject.text;
        if (!q.length) return;
        [self runSearch:q];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)runSearch:(NSString *)q {
    MKLog(@"地图搜索: %@", q);
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery = q;
    req.region = self.mapView.region;

    MKLocalSearch *s = [[MKLocalSearch alloc] initWithRequest:req];
    [s startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *err) {
        if (err || resp.mapItems.count == 0) {
            MKLog(@"搜索失败: %@ (items=%lu)", err.localizedDescription, (unsigned long)resp.mapItems.count);
            MKAlert(@"没找到", @"换个关键词试试，或检查网络。");
            return;
        }
        MKMapItem *it = resp.mapItems.firstObject;
        CLLocationCoordinate2D c = it.placemark.coordinate;
        MKLog(@"搜索命中: %@ (%.6f,%.6f)", it.name, c.latitude, c.longitude);
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 600, 600) animated:YES];
    }];
}

- (void)doLocateSelf {
    if (!_locMgr) {
        _locMgr = [CLLocationManager new];
        _locMgr.delegate = self;
        _locMgr.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    }
    if (_locMgr.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [_locMgr requestWhenInUseAuthorization];
    }
    [_locMgr startUpdatingLocation];
    MKLog(@"定位自己: 开始");
}

- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)locs {
    if (!locs.count) return;
    CLLocation *l = locs.lastObject;
    [m stopUpdatingLocation];
    MKLog(@"定位自己: %.6f,%.6f", l.coordinate.latitude, l.coordinate.longitude);
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(l.coordinate, 800, 800) animated:YES];
}

- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)e {
    MKLog(@"定位自己失败: %@", e.localizedDescription);
}

- (void)doConfirm {
    if (self.resolving) return;
    self.resolving = YES;
    self.okButton.enabled = NO;
    [self.okButton setTitle:@"反查中…" forState:UIControlStateNormal];

    CLLocationCoordinate2D gcj = self.mapView.centerCoordinate;
    CLLocationCoordinate2D wgs = MKWGS84FromGCJ02(gcj.latitude, gcj.longitude);
    MKLog(@"地图确定 GCJ=(%.6f,%.6f) WGS=(%.6f,%.6f)", gcj.latitude, gcj.longitude, wgs.latitude, wgs.longitude);

    CLLocation *loc = [[CLLocation alloc] initWithLatitude:gcj.latitude longitude:gcj.longitude];
    CLGeocoder *geo = [CLGeocoder new];
    __block BOOL finished = NO;

    void (^finish)(NSString *) = ^(NSString *addr) {
        if (finished) return;
        finished = YES;
        NSString *finalAddr = addr.length ? addr : [NSString stringWithFormat:@"%.6f,%.6f", wgs.latitude, wgs.longitude];
        MKFakeCfg *c = CFG();
        c.lat = wgs.latitude;
        c.lng = wgs.longitude;
        c.addr = finalAddr;
        c.locOn = YES;
        [c save];
        MKLog(@"地图选点保存: %.6f,%.6f %@", c.lat, c.lng, c.addr);
        if (self.onPick) self.onPick(c.lat, c.lng, c.addr);
        [self dismissViewControllerAnimated:YES completion:nil];
    };

    // 超时兜底：4 秒没回来就只用坐标
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(nil); });

    [geo reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *pm, NSError *err) {
        if (err || !pm.count) {
            MKLog(@"反查地址失败: %@", err.localizedDescription);
            finish(nil);
            return;
        }
        CLPlacemark *p = pm.firstObject;
        NSMutableArray *parts = [NSMutableArray array];
        if (p.administrativeArea.length) [parts addObject:p.administrativeArea];
        if (p.locality.length && ![p.locality isEqualToString:p.administrativeArea]) [parts addObject:p.locality];
        if (p.subLocality.length) [parts addObject:p.subLocality];
        if (p.thoroughfare.length) [parts addObject:p.thoroughfare];
        if (p.subThoroughfare.length) [parts addObject:p.subThoroughfare];
        if (p.name.length && ![[parts componentsJoinedByString:@""] containsString:p.name]) {
            [parts addObject:p.name];
        }
        NSString *addr = [parts componentsJoinedByString:@""];
        MKLog(@"反查地址: %@", addr);
        finish(addr);
    }];
}

@end

// =============================================================================
//  MARK: - 日志查看
// =============================================================================

@interface MKLogViewController : UIViewController
@end

@implementation MKLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MKC_RGB(20, 20, 26);

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)];
    bar.backgroundColor = MKC_RGBA(38, 38, 46, 0.98);
    bar.tag = 8001;
    [self.view addSubview:bar];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 54, bar.bounds.size.width, 26)];
    t.text = @"运行日志";
    t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont boldSystemFontOfSize:16];
    t.textColor = MKC_TEXT();
    [bar addSubview:t];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(10, 52, 60, 30);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(bar.bounds.size.width - 70, 52, 60, 30);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    [clear setTitleColor:MKC_RED() forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearTap) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:clear];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 96, self.view.bounds.size.width,
                                                                  self.view.bounds.size.height - 96)];
    tv.tag = 8002;
    tv.backgroundColor = MKC_RGB(20, 20, 26);
    tv.textColor = MKC_RGBA(140, 250, 180, 0.92);
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.editable = NO;
    tv.text = MKLogWhole();
    tv.textContainerInset = UIEdgeInsetsMake(10, 10, 24, 10);
    tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:tv];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSRange r = NSMakeRange(tv.text.length ? tv.text.length - 1 : 0, 1);
        [tv scrollRangeToVisible:r];
    });
}

- (void)closeTap {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearTap {
    [[NSFileManager defaultManager] removeItemAtPath:MKLogFilePath() error:NULL];
    UITextView *tv = (UITextView *)[self.view viewWithTag:8002];
    tv.text = @"（日志已清空）";
    MKLog(@"日志已清空");
}

@end

// =============================================================================
//  MARK: - 主控制面板
// =============================================================================

@interface MKPanelViewController : UIViewController <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIView   *card;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *coordLabel;
@property (nonatomic, strong) NSMutableArray<UISwitch *> *switches;
@end

@implementation MKPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MKC_RGBA(0, 0, 0, 0.42);
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.switches = [NSMutableArray array];
    [self buildCard];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTap:)];
    [self.view addGestureRecognizer:tap];
}

- (void)backgroundTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (!CGRectContainsPoint(self.card.frame, p)) {
        [self closeTap];
    }
}

- (void)buildCard {
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat cardW = W - 28;
    CGFloat cw = cardW - 28;          // 内容宽
    CGFloat pad = 14;

    // ---- 先算高度 ----
    CGFloat y = pad;
    CGFloat headerH = 44;
    CGFloat statusH = 74;
    CGFloat coordH  = 20;
    CGFloat rowH    = 54;
    CGFloat footH   = 42;
    CGFloat contentH = pad + headerH + 8 + statusH + 6 + coordH + 10 + rowH * 5 + 10 + footH + pad;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, contentH)];
    card.backgroundColor = MKC_BG();
    card.layer.cornerRadius = 18;
    card.layer.masksToBounds = NO;
    card.layer.borderWidth = 0.6;
    card.layer.borderColor = MKC_RGBA(255, 255, 255, 0.10).CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.45;
    card.layer.shadowRadius = 24;
    card.layer.shadowOffset = CGSizeMake(0, 10);
    card.center = CGPointMake(W / 2, H / 2);
    [self.view addSubview:card];
    self.card = card;

    // ---- 标题 ----
    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(pad, y + 8, 3, 22)];
    accent.backgroundColor = MKC_BLUE();
    accent.layer.cornerRadius = 1.5;
    [card addSubview:accent];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad + 10, y + 2, cw - 80, 22)];
    title.text = @"MarkiFake 控制台";
    title.font = [UIFont boldSystemFontOfSize:16.5];
    title.textColor = MKC_TEXT();
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(pad + 10, y + 24, cw - 80, 16)];
    sub.text = @"像素级换图 · 定位 · 时间 · 天气";
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = MKC_SUB();
    [card addSubview:sub];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(cardW - pad - 28, y + 8, 28, 28);
    close.backgroundColor = MKC_RGBA(255, 255, 255, 0.08);
    close.layer.cornerRadius = 14;
    UILabel *x = [[UILabel alloc] initWithFrame:close.bounds];
    x.text = @"✕";
    x.textAlignment = NSTextAlignmentCenter;
    x.textColor = MKC_TEXT();
    x.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    x.userInteractionEnabled = NO;
    [close addSubview:x];
    [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    y += headerH + 8;

    // ---- 状态区 ----
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, statusH)];
    box.backgroundColor = MKC_BOX();
    box.layer.cornerRadius = 10;
    [card addSubview:box];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, 9, cw - 24, 56)];
    st.numberOfLines = 0;
    st.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    st.textColor = MKC_RGBA(235, 235, 245, 0.85);
    [box addSubview:st];
    self.statusLabel = st;

    y += statusH + 6;

    UILabel *coord = [[UILabel alloc] initWithFrame:CGRectMake(pad + 2, y, cw - 4, coordH)];
    coord.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    coord.textColor = MKC_SUB();
    coord.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [card addSubview:coord];
    self.coordLabel = coord;

    y += coordH + 10;

    // ---- 5 行功能 ----
    NSArray<NSString *> *rowTitles  = @[@"假定位", @"假时间", @"改天气", @"相册替拍", @"反作弊归零"];
    NSArray<NSString *> *btnTitles  = @[@"地图选点", @"设置时间", @"选择天气", @"选择图片", @"全部关闭"];
    NSArray<UIColor *>  *accents    = @[MKC_GREEN(), MKC_ORANGE(), MKC_RED(), MKC_TEAL(), MKC_PURPLE()];
    NSArray<UIColor *>  *btnColors  = @[MKC_BLUE(), MKC_ORANGE(), MKC_ORANGE(), MKC_BLUE(), MKC_RED()];

    for (NSInteger i = 0; i < rowTitles.count; i++) {
        [self addRowAtY:y index:i title:rowTitles[i] accent:accents[i]
               btnTitle:btnTitles[i] btnColor:btnColors[i] contentW:cw pad:pad];
        y += rowH;
    }

    y += 10;

    // ---- 底部：查看日志 ----
    UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    logBtn.frame = CGRectMake(pad, y, cw, footH);
    logBtn.backgroundColor = MKC_RGBA(255, 255, 255, 0.07);
    logBtn.layer.cornerRadius = 10;
    [logBtn setTitle:@"查看运行日志" forState:UIControlStateNormal];
    [logBtn setTitleColor:MKC_TEXT() forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [logBtn addTarget:self action:@selector(logTap) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:logBtn];

    [self refreshStatus];
}

- (void)addRowAtY:(CGFloat)y index:(NSInteger)idx title:(NSString *)title accent:(UIColor *)accent
         btnTitle:(NSString *)btnTitle btnColor:(UIColor *)btnColor contentW:(CGFloat)cw pad:(CGFloat)pad {

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 54)];
    [self.card addSubview:row];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 16, 3, 22)];
    bar.backgroundColor = accent;
    bar.layer.cornerRadius = 1.5;
    [row addSubview:bar];

    CGFloat btnW = 86;
    CGFloat btnX = cw - btnW;
    CGFloat swW = 51, swH = 31;
    CGFloat swX = btnX - 10 - swW;

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, swX - 12, 54)];
    lab.text = title;
    lab.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
    lab.textColor = MKC_TEXT();
    [row addSubview:lab];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(swX, (54 - swH) / 2, swW, swH)];
    sw.tag = 7300 + idx;
    sw.onTintColor = accent;
    sw.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    [self.switches addObject:sw];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(btnX, (54 - 32) / 2, btnW, 32);
    btn.backgroundColor = btnColor;
    btn.layer.cornerRadius = 9;
    [btn setTitle:btnTitle forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    btn.tag = 7400 + idx;
    [btn addTarget:self action:@selector(actionTap:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:btn];
}

// ---- 状态刷新 ----
- (void)refreshStatus {
    MKFakeCfg *c = CFG();
    [self.switches[0] setOn:c.locOn       animated:NO];
    [self.switches[1] setOn:c.timeOn      animated:NO];
    [self.switches[2] setOn:c.wxOn        animated:NO];
    [self.switches[3] setOn:c.photoOn     animated:NO];
    [self.switches[4] setOn:c.antiOn      animated:NO];

    NSString *(^Y)(BOOL) = ^NSString *(BOOL on) { return on ? @"开" : @"关"; };
    self.statusLabel.text = [NSString stringWithFormat:
        @"定位：%@   时间：%@\n天气：%@   替拍：%@\n反作弊：%@   %@",
        Y(c.locOn), Y(c.timeOn), Y(c.wxOn), Y(c.photoOn), Y(c.antiOn),
        c.photoAlways ? @"常开" : (c.photoOn ? @"窗口" : @"")];

    NSString *img = c.imgPath.length ? c.imgPath : @"@latest";
    if (img.length > 28) img = [img substringFromIndex:img.length - 28];
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f  ·  %@", c.lat, c.lng, img];
}

// ---- 开关 ----
- (void)switchChanged:(UISwitch *)sw {
    MKFakeCfg *c = CFG();
    NSInteger idx = sw.tag - 7300;
    BOOL on = sw.on;
    switch (idx) {
        case 0: c.locOn = on; gFakeLoc = nil; gFakeLat = -9999; gFakeLng = -9999; break;
        case 1: c.timeOn = on; MKRefreshFakeDate(); break;   // 关掉也要重算，否则偏移不收回
        case 2: c.wxOn = on; break;
        case 3:
            c.photoOn = on;
            if (on) {
                c.photoAlways = NO;
                c.photoUntil = MKUnixNow() + 600;
                MKPrefetchSwapImage();
            }
            break;
        case 4: c.antiOn = on; break;
    }
    [c save];
    [self refreshStatus];
    MKLog(@"开关 %ld → %d", (long)idx, (int)on);
    MKSnack([NSString stringWithFormat:@"%@ 已%@",
             @[@"定位", @"时间", @"天气", @"相册替拍", @"反作弊"][MIN(idx, 4)], on ? @"开启" : @"关闭"]);
}

// ---- 按钮 ----
- (void)actionTap:(UIButton *)b {
    NSInteger idx = b.tag - 7400;
    MKFakeCfg *c = CFG();

    if (idx == 0) {                       // 地图选点
        MKMapPickerViewController *vc = [MKMapPickerViewController new];
        __weak typeof(self) weakSelf = self;
        vc.onPick = ^(double lat, double lng, NSString *addr) {
            MKLog(@"面板收到地图选点 %.6f,%.6f %@", lat, lng, addr);
            [weakSelf refreshStatus];
            MKSnack(@"定位已更新");
        };
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
        return;
    }

    if (idx == 1) {                       // 设置时间
        MKDatePickerSheet *vc = [MKDatePickerSheet new];
        NSDateComponents *cc = [NSDateComponents new];
        NSArray *p = [c.fakeTime componentsSeparatedByString:@" "];
        NSArray *d = [p.firstObject componentsSeparatedByString:@"-"];
        NSArray *t = [p.lastObject componentsSeparatedByString:@":"];
        if (d.count == 3 && t.count >= 2) {
            cc.year = [d[0] integerValue]; cc.month = [d[1] integerValue]; cc.day = [d[2] integerValue];
            cc.hour = [t[0] integerValue]; cc.minute = [t[1] integerValue];
            cc.second = t.count > 2 ? [t[2] integerValue] : 0;
            NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
            vc.initialDate = [cal dateFromComponents:cc];
        }
        __weak typeof(self) weakSelf = self;
        vc.onDone = ^(NSDate *date) {
            c.fakeTime = MKFormatDateManual(date);
            c.timeOn = YES;
            [c save];
            MKRefreshFakeDate();
            [weakSelf refreshStatus];
            MKSnack([NSString stringWithFormat:@"假时间 %@", c.fakeTime]);
        };
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:vc animated:YES completion:nil];
        return;
    }

    if (idx == 2) {                       // 选择天气
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"修改天气"
                             message:@"格式：天气,温度   例：多云,18"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [NSString stringWithFormat:@"%@,%lld", c.wxText, c.wxTemp];
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            NSString *s = ac.textFields.firstObject.text;
            NSArray *arr = [s componentsSeparatedByString:@","];
            if (arr.count >= 1 && [arr[0] length]) c.wxText = arr[0];
            if (arr.count >= 2) c.wxTemp = [arr[1] integerValue];
            c.wxOn = YES;
            [c save];
            [weakSelf refreshStatus];
            MKSnack([NSString stringWithFormat:@"天气 %@ %lld°", c.wxText, c.wxTemp]);
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (idx == 3) {                       // 相册替拍：直接用 PHPicker 选图
        PHPickerConfiguration *conf = [[PHPickerConfiguration alloc] init];
        conf.filter = [PHPickerFilter imagesFilter];
        conf.selectionLimit = 1;
        conf.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:conf];
        pk.delegate = self;
        [self presentViewController:pk animated:YES completion:^{
            MKLog(@"PHPicker 已打开");
        }];
        return;
    }

    if (idx == 4) {                       // 全部关闭
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"全部关闭"
                             message:@"所有篡改暂停，hook 保留并直通原实现"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [ac addAction:[UIAlertAction actionWithTitle:@"确认关闭"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            c.locOn = NO; c.timeOn = NO; c.wxOn = NO;
            c.photoOn = NO; c.photoAlways = NO; c.photoUntil = 0;
            c.antiOn = NO;
            [c save];
            MKRefreshFakeDate();          // 收回时钟偏移
            [weakSelf refreshStatus];
            MKSnack(@"已全部关闭");
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
}

- (void)logTap {
    MKLog(@"打开日志查看器");
    MKLogViewController *vc = [MKLogViewController new];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)closeTap {
    MKLog(@"面板关闭");
    [self dismissViewControllerAnimated:YES completion:^{
        gPanelOnScreen = NO;
    }];
}

@end


// =============================================================================
//  MARK: - PHPicker 代理
// =============================================================================

@implementation MKPanelViewController (PHPicker)

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (!results.count) {
        MKLog(@"PHPicker 取消");
        return;
    }

    PHPickerResult *r = results.firstObject;
    NSItemProvider *prov = r.itemProvider;
    MKLog(@"PHPicker 选中 %@ types=%@", prov.suggestedName, prov.registeredTypeIdentifiers);

    __weak typeof(self) weakSelf = self;

    void (^saveImage)(UIImage *) = ^(UIImage *img) {
        if (!img) { MKAlert(@"读图失败", @"这张图读不出来，换一张试试"); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *path = [doc stringByAppendingPathComponent:@"swap_custom.jpg"];
            NSData *jpeg = UIImageJPEGRepresentation(img, 0.92);
            BOOL ok = jpeg.length && [jpeg writeToFile:path atomically:YES];
            MKLog(@"PHPicker 写盘 %@ %lu B ok=%d", path, (unsigned long)jpeg.length, ok);

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) { MKAlert(@"保存失败", path); return; }
                MKFakeCfg *c = CFG();
                c.imgPath = path;
                c.photoOn = YES;
                c.photoAlways = NO;
                c.photoUntil = MKUnixNow() + 600;
                [c save];
                MKPrefetchSwapImage();
                [weakSelf refreshStatus];
                MKSnack([NSString stringWithFormat:@"换图已设定 %.0f×%.0f", img.size.width, img.size.height]);
            });
        });
    };

    if ([prov canLoadObjectOfClass:[UIImage class]]) {
        [prov loadObjectOfClass:[UIImage class]
              completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
            if (err) MKLog(@"PHPicker loadObject 失败: %@", err.localizedDescription);
            saveImage((UIImage *)obj);
        }];
        return;
    }

    // 兜底：不解码，直接拿原始文件（HEIC 等）
    NSString *uti = prov.registeredTypeIdentifiers.firstObject;
    if (!uti) { MKAlert(@"选图失败", @"该资源没有可用类型"); return; }
    MKLog(@"PHPicker 走 fileRepresentation uti=%@", uti);
    [prov loadFileRepresentationForTypeIdentifier:uti
                                completionHandler:^(NSURL *url, NSError *err) {
        if (err || !url) {
            MKLog(@"PHPicker 取文件失败: %@", err.localizedDescription);
            MKAlert(@"读图失败", err.localizedDescription ?: @"未知错误");
            return;
        }
        // 这个 url 在回调返回后会被删掉，必须先读进内存
        NSData *data = [NSData dataWithContentsOfURL:url];
        MKLog(@"PHPicker 读到 %lu B", (unsigned long)data.length);
        saveImage(data.length ? [UIImage imageWithData:data] : nil);
    }];
}

@end

static void MKShowPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanelOnScreen) { MKLog(@"面板已在显示"); return; }
        UIViewController *top = MKTopVC();
        if (!top) { MKLog(@"弹面板失败：没有顶层 VC"); return; }
        if ([top isKindOfClass:[UIAlertController class]]) {
            MKLog(@"已有系统弹窗，先关掉再开面板");
            return;
        }

        MKPanelViewController *vc = [MKPanelViewController new];
        gPanelOnScreen = YES;
        [top presentViewController:vc animated:YES completion:^{
            MKLog(@"面板已弹出");
            // present 失败时 UI 不会出现，1 秒后解闩
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (vc.presentingViewController == nil && gPanelOnScreen) {
                    gPanelOnScreen = NO;
                    MKLog(@"面板未能挂上，已解锁");
                }
            });
        }];
        MKLog(@"面板 present 请求已发出 (from %@)", NSStringFromClass([top class]));
    });
}

// =============================================================================
//  MARK: - 去广告
// =============================================================================

@interface MKAdBlockProtocol : NSURLProtocol
@end

@implementation MKAdBlockProtocol

+ (NSArray<NSString *> *)mk_adKeywords {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            // 穿山甲 / 字节
            @"pangolin", @"snssdk", @"bytedance", @"pangle", @"byteimg.com/ad",
            // 优量汇
            @"gdt.qq.com", @"e.qq.com", @"adsmind", @"adnet.qq",
            // 快手
            @"kuaishou", @"gifshow", @"kwai",
            // 百度
            @"cpro", @"mobads", @"baidu.com/ad", @"union.baidu",
            // 京准通 / 其它常见联盟
            @"jd.com/ad", @"tanx.com", @"alimama", @"umeng.com/ad",
            // 通用路径
            @"/api/ad", @"/ad/get", @"/adx", @"/splash/ad", @"/api/v1/ad",
        ];
    });
    return a;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    // 递归保护：打过标记的直接放过，避免自己拦自己
    if ([NSURLProtocol propertyForKey:@"MKAdBlocked" inRequest:request]) return NO;
    if (!CFG().adBlockOn) return NO;

    NSString *s = request.URL.absoluteString.lowercaseString;
    if (!s.length) return NO;

    for (NSString *k in [self mk_adKeywords]) {
        if ([s containsString:k]) {
            MKLOG_ONCE(@"广告拦截命中关键字 %@ — 例: %@", k, s);
            MKLog(@"拦截广告 %@", s.length > 140 ? [s substringToIndex:140] : s);
            return YES;
        }
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return NO;
}

- (void)startLoading {
    MKLog(@"屏蔽请求(NSURLErrorCancelled)：%@", self.request.URL.absoluteString);
    NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                       code:NSURLErrorCancelled
                                   userInfo:@{ NSLocalizedDescriptionKey : @"blocked by MarkiFake" }];
    [self.client URLProtocol:self didFailWithError:err];
}

- (void)stopLoading { }

@end

// 有些 SDK 会自己 set 一套 protocolClasses，把它挤掉；这里强制前置
static IMP o_setProtocolClasses = NULL;
static void h_setProtocolClasses(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *arr = [NSMutableArray arrayWithObject:[MKAdBlockProtocol class]];
    for (id c in classes) if (c != [MKAdBlockProtocol class]) [arr addObject:c];
    ((void (*)(id, SEL, id))o_setProtocolClasses)(self, _cmd, arr);
}

static void MKInstallAdBlock(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    [NSURLProtocol registerClass:[MKAdBlockProtocol class]];
    o_setProtocolClasses = MKHook(objc_getClass("NSURLSessionConfiguration"),
                                  MKSEL(setProtocolClasses:), (IMP)h_setProtocolClasses,
                                  "-[NSURLSessionConfiguration setProtocolClasses:]");
    MKLog(@"去广告已注册，关键字 %lu 条",
          (unsigned long)[MKAdBlockProtocol mk_adKeywords].count);
}

// =============================================================================
//  MARK: - 启动
// =============================================================================

static void MKInstallAllHooks(void) {
    MKLog(@"========== MarkiFake 启动  pid=%d ==========", getpid());
    MKLog(@"bundle=%@ exe=%@", [[NSBundle mainBundle] bundleIdentifier],
          [[NSBundle mainBundle] infoDictionary][@"CFBundleExecutable"]);

    MKInstallLocationHooks();
    MKInstallAntiCheatHooks();
    MKInstallCameraHooks();
    MKInstallTimeHooks();
    MKInstallWeatherHooks();

    MKInstallAdBlock();
    MKLog(@"日志文件: %@", MKLogFilePath());
}

static void MKSchedulePanel(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        // GLCameraSDK 可能是运行时 dlopen 的，构造期还看不到这些类，每次回前台补一次
        if (o_vsInit == NULL) {
            MKLog(@"补挂相机 hook（GLCameraSDK 应已加载）");
            MKInstallCameraHooks();
        }
        if (o_gmUpdateItem == NULL) {
            MKLog(@"补挂天气 hook（GPUMarkSDK 应已加载）");
            MKInstallWeatherHooks();
        }
        if (gPanelShown) return;
        gPanelShown = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MKLog(@"首次进入前台 → 弹面板");
            MKInstallFAB();
            MKShowPanel();
            if (CFG().photoOn) MKPrefetchSwapImage();
        });
    }];
}

__attribute__((constructor))
static void MKFakeInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (!([bid isEqualToString:@"com.ai.marki"] || [bid containsString:@"marki"])) {
            NSLog(@"[MKFake] 当前不是 marki（bundle=%@），不注入", bid);
            return;
        }
        MKInstallAllHooks();
        MKSchedulePanel();
    }
}
