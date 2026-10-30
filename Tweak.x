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
        _flipY = YES;
        _fab = YES;
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

     MKLog(@"[%@] pb=%p %zu×%zu fmt=%@ bpr=%zu planar=%d iosurface=%p",
          tag, pb, w, h, MKFourCC(fmt), bpr, planar,
          (void *)CVPixelBufferGetIOSurface(pb));

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

static void MKInstallTimeHooks(void) {
    MKRefreshFakeDate();
    o_stringFromDate = MKHook(objc_getClass("NSDateFormatter"), @selector(stringFromDate:),
                              (IMP)h_stringFromDate, "-[NSDateFormatter stringFromDate:]");
    o_dateNow = MKHookClass(objc_getClass("NSDate"), @selector(now), (IMP)h_dateNow, "+[NSDate now]");
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

static void MKInstallWeatherHooks(void) {
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

static UIWindow *gFABWindow = nil;
static BOOL gPanelShown = NO;
static BOOL gPanelBusy = NO;

// 触摸穿透窗口：只有悬浮球自己接收事件，其它全部漏给下面的 App
@interface MKFABWindow : UIWindow
@end
@implementation MKFABWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static UIViewController *MKTopVC(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
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

// 简单提示框；延后 0.45s，避免和正在消失的 alert 抢 presentation
static void MKAlert(NSString *title, NSString *msg) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
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
        b.frame = CGRectMake(10, 150, 44, 44);
        b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        b.layer.cornerRadius = 22;
        b.layer.masksToBounds = YES;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6].CGColor;
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

static void MKShowPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanelBusy) { MKLog(@"面板正在展示，忽略重复调用"); return; }

        UIViewController *top = MKTopVC();
        if (!top) { MKLog(@"弹面板失败：没有顶层 VC"); return; }
        if ([top isKindOfClass:[UIAlertController class]]) { MKLog(@"已有 alert，先关掉再来"); return; }

        gPanelBusy = YES;
        MKFakeCfg *c = CFG();

        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"MarkiFake 控制台"
                             message:@"点「保存并启用」后开始生效；换图窗口 10 分钟，拍一张即用。"
                      preferredStyle:UIAlertControllerStyleAlert];

        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"纬度 lat";
            tf.text = [NSString stringWithFormat:@"%.6f", c.lat];
            tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"经度 lng";
            tf.text = [NSString stringWithFormat:@"%.6f", c.lng];
            tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"假地址（水印文字）";
            tf.text = c.addr;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"换图路径，或 @latest";
            tf.text = c.imgPath;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        void (^readFields)(void) = ^{
            NSArray<UITextField *> *tf = ac.textFields;
            if (tf.count < 4) return;
            double lat = tf[0].text.doubleValue;
            double lng = tf[1].text.doubleValue;
            if (fabs(lat) > 1e-6 || fabs(lng) > 1e-6) { c.lat = lat; c.lng = lng; }
            if (tf[2].text.length) c.addr = tf[2].text;
            if (tf[3].text.length) c.imgPath = tf[3].text;
        };

        [ac addAction:[UIAlertAction actionWithTitle:@"保存并启用（定位/时间/天气/换图）"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            readFields();
            c.locOn = YES; c.timeOn = YES; c.wxOn = YES; c.antiOn = YES;
            c.photoOn = YES; c.photoAlways = NO;
            c.photoUntil = MKUnixNow() + 600;
            gFakeLoc = nil; gFakeLat = -9999; gFakeLng = -9999;
            [c save];
            MKRefreshFakeDate();
            MKPrefetchSwapImage();
            MKAlert(@"已启用", [NSString stringWithFormat:
                @"定位 %.6f, %.6f\n地址 %@\n换图 %@（10 分钟）\n假时间 %@\n反作弊已归零",
                c.lat, c.lng, c.addr, c.imgPath, c.fakeTime]);
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"换图常开"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            readFields();
            c.photoOn = YES; c.photoAlways = YES; c.photoUntil = 0;
            [c save];
            MKPrefetchSwapImage();
            MKAlert(@"换图已常开", c.imgPath);
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"只关换图"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            c.photoOn = NO; c.photoAlways = NO; c.photoUntil = 0;
            [c save];
            MKAlert(@"换图已关闭", @"像素不再被替换");
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"全部关闭"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            c.locOn = NO; c.timeOn = NO; c.wxOn = NO;
            c.photoOn = NO; c.photoAlways = NO; c.photoUntil = 0;
            c.antiOn = NO;
            [c save];
            MKAlert(@"已全部关闭", @"hook 还在，但全部直通原实现");
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"倒图/花屏开关（flipY）"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            c.flipY = !c.flipY;
            [c save];
            MKAlert(@"已切换", [NSString stringWithFormat:
                @"flipY = %@\n若照片上下颠倒，点这里换一次再拍；花屏同理。",
                c.flipY ? @"YES" : @"NO"]);
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"查看日志"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            MKLog(@"用户查看日志: %@", MKLogFilePath());
            MKAlert(@"最近日志", MKLogTail(22));
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) {
            MKLog(@"面板取消");
        }]];

        [top presentViewController:ac animated:YES completion:^{
            MKLog(@"面板已弹出");
            gPanelBusy = NO;
        }];

        // 兜底：present 失败时解锁
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gPanelBusy = NO; });
    });
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
