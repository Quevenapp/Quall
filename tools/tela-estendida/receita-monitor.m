// Que receita de CGVirtualDisplay faz um formato nascer em 2x — e o que o macOS oferece com ela.
// Foi a ferramenta de "A regra do 2x" (docs/tela-estendida.md, 11/09/2026).
//
// Um monitor por processo (limite medido), e a lista de modos lida **de dentro** dele: visto de
// outro processo, `CGDisplayCopyDisplayMode` não é testemunha para monitor virtual. Só propriedade
// de monitor — nada de pixel. O monitor some quando o processo sai.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics receita-monitor.m -o receita-monitor
//   receita-monitor --alvo=1920x884 --serie=N                      # a receita de hoje: modo em pontos
//   receita-monitor --alvo=1920x884 --modos=1920x884 --serie=N     # a de antes: modo em pixels
//   [--max=LxA] [--modos=LxA,...] [--hidpi=0|1] [--mm=LxA | --ppi=206] [--hz=30] [--segundos=1]
//   [--fixar]   # tenta fixar o 2x do alvo se ele não nasceu nele, e diz o CGError
//   [--props]   # as propriedades das quatro classes privadas, lidas do runtime
//
// **Série nova a cada medida**: o macOS lembra o modo por identidade, e uma série reusada mede a
// lembrança, não a receita. As de 11/09 foram de 20737 a 20788 (vendor e produto do Quall). E
// **ninguém transmitindo** antes (`pgrep -f "MacOS/quall-monitor-virtua[l]"`).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>

@protocol RDescritor <NSObject>
@property (nonatomic, strong) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, strong) dispatch_queue_t queue;
@end
@protocol RModo <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@protocol RAjustes <NSObject>
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@protocol RMonitor <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

static double agoraMs(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static BOOL par(NSString *s, unsigned *a, unsigned *b) {
    NSArray *p = [[s lowercaseString] componentsSeparatedByString:@"x"];
    if (p.count != 2) return NO;
    *a = (unsigned)[p[0] intValue]; *b = (unsigned)[p[1] intValue];
    return *a > 0 && *b > 0;
}

static BOOL online(CGDirectDisplayID id) {
    uint32_t n = 0; CGDirectDisplayID ids[32];
    if (CGGetOnlineDisplayList(32, ids, &n) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) if (ids[i] == id) return YES;
    return NO;
}

static NSString *desc(CGDisplayModeRef m) {
    if (!m) return @"(sem modo)";
    uint32_t f = CGDisplayModeGetIOFlags(m);
    NSMutableString *s = [NSMutableString stringWithFormat:@"%zux%zu pt / %zux%zu px @%.0f Hz flags=0x%08x",
        CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
        CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
        CGDisplayModeGetRefreshRate(m), f];
    if (f & 0x00000004) [s appendString:@" DEFAULT"];
    if (f & 0x02000000) [s appendString:@" NATIVE"];
    if (!CGDisplayModeIsUsableForDesktopGUI(m)) [s appendString:@" nao-gui"];
    if (CGDisplayModeGetPixelWidth(m) == 2 * CGDisplayModeGetWidth(m)) [s appendString:@" [2x]"];
    return s;
}

static void props(NSString *classe) {
    Class c = NSClassFromString(classe);
    if (!c) { printf("%s: ausente\n", classe.UTF8String); return; }
    unsigned n = 0;
    objc_property_t *ps = class_copyPropertyList(c, &n);
    printf("%s:", classe.UTF8String);
    for (unsigned i = 0; i < n; i++) printf(" %s", property_getName(ps[i]));
    printf("\n");
    free(ps);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        unsigned alvoL = 0, alvoA = 0, maxL = 0, maxA = 0, mmL = 0, mmA = 0;
        unsigned hidpi = 1, serie = 0; double hz = 30, segundos = 1, ppi = 206;
        BOOL fixar = NO, listarProps = NO;
        NSMutableArray<NSString *> *modos = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            NSArray *kv = [a componentsSeparatedByString:@"="];
            NSString *k = kv[0], *v = kv.count > 1 ? kv[1] : @"";
            if ([k isEqual:@"--alvo"]) par(v, &alvoL, &alvoA);
            else if ([k isEqual:@"--max"]) par(v, &maxL, &maxA);
            else if ([k isEqual:@"--mm"]) par(v, &mmL, &mmA);
            else if ([k isEqual:@"--modos"]) [modos addObjectsFromArray:[v componentsSeparatedByString:@","]];
            else if ([k isEqual:@"--hidpi"]) hidpi = (unsigned)v.intValue;
            else if ([k isEqual:@"--serie"]) serie = (unsigned)v.intValue;
            else if ([k isEqual:@"--hz"]) hz = v.doubleValue;
            else if ([k isEqual:@"--ppi"]) ppi = v.doubleValue;
            else if ([k isEqual:@"--segundos"]) segundos = v.doubleValue;
            else if ([k isEqual:@"--fixar"]) fixar = YES;
            else if ([k isEqual:@"--props"]) listarProps = YES;
            else { fprintf(stderr, "argumento desconhecido: %s\n", argv[i]); return 2; }
        }
        if (listarProps) {
            for (NSString *c in @[@"CGVirtualDisplay", @"CGVirtualDisplayDescriptor",
                                  @"CGVirtualDisplaySettings", @"CGVirtualDisplayMode"]) props(c);
            if (alvoL == 0) return 0;
        }
        if (alvoL == 0 || serie == 0) { fprintf(stderr, "faltam --alvo e --serie\n"); return 2; }
        if (maxL == 0) { maxL = alvoL; maxA = alvoA; }
        // Sem `--modos`, a receita do produto: o painel em pontos (`QuallMonitorVirtual.m`).
        if (modos.count == 0) [modos addObject:[NSString stringWithFormat:@"%ux%u", alvoL / 2, alvoA / 2]];
        double mmW = mmL ? mmL : round(maxL * 25.4 / ppi), mmH = mmA ? mmA : round(maxA * 25.4 / ppi);
        if (mmL == 0 && maxL != alvoL) {
            // O painel é o alvo; o máximo pode ser maior. O tamanho físico é o do painel.
            mmW = round(alvoL * 25.4 / ppi); mmH = round(alvoA * 25.4 / ppi);
        }
        printf("RECEITA alvo=%ux%u max=%ux%u modos=%s hidpi=%u mm=%.0fx%.0f hz=%.0f serie=%u\n",
               alvoL, alvoA, maxL, maxA, [[modos componentsJoinedByString:@","] UTF8String], hidpi, mmW, mmH, hz, serie);

        __block int codigo = 1;
        dispatch_semaphore_t pronto = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id<RDescritor> d = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            d.name = [NSString stringWithFormat:@"Quall (receita %u)", serie];
            d.maxPixelsWide = maxL; d.maxPixelsHigh = maxA;
            d.sizeInMillimeters = CGSizeMake(mmW, mmH);
            d.vendorID = 0x458C; d.productID = 0x0001; d.serialNum = serie;
            d.queue = dispatch_queue_create("receita", DISPATCH_QUEUE_SERIAL);
            double t0 = agoraMs();
            id<RMonitor> mon = [(id<RMonitor>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
            if (!mon || mon.displayID == kCGNullDirectDisplay) { printf("FALHA initWithDescriptor\n"); dispatch_semaphore_signal(pronto); return; }
            id<RAjustes> aj = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            NSMutableArray *ms = [NSMutableArray array];
            for (NSString *m in modos) {
                unsigned w, h;
                if (!par(m, &w, &h)) { printf("modo ilegível: %s\n", m.UTF8String); continue; }
                [ms addObject:[(id<RModo>)[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:hz]];
            }
            aj.hiDPI = hidpi; aj.modes = ms;
            BOOL ok = [mon applySettings:aj];
            CGDirectDisplayID did = mon.displayID;
            printf("id=%u applySettings=%s criar=%.0f ms\n", did, ok ? "sim" : "NAO", agoraMs() - t0);
            if (!ok) { dispatch_semaphore_signal(pronto); return; }
            double t1 = agoraMs(); BOOL on = NO;
            while (agoraMs() - t1 < 5000) { if (online(did)) { on = YES; break; } usleep(20000); }
            printf("online: %s em %.0f ms\n", on ? "sim" : "NAO", agoraMs() - t1);
            if (!on) { dispatch_semaphore_signal(pronto); return; }
            double t2 = agoraMs(); CGDisplayModeRef atual = NULL;
            while (agoraMs() - t2 < 3000) { atual = CGDisplayCopyDisplayMode(did); if (atual) break; usleep(20000); }
            printf("modo em %.0f ms | nasceu: %s | bounds %.0fx%.0f\n", agoraMs() - t2, desc(atual).UTF8String,
                   CGDisplayBounds(did).size.width, CGDisplayBounds(did).size.height);
            BOOL nasceuNoAlvo = atual && CGDisplayModeGetPixelWidth(atual) == alvoL && CGDisplayModeGetPixelHeight(atual) == alvoA
                && CGDisplayModeGetWidth(atual) == alvoL / 2 && CGDisplayModeGetHeight(atual) == alvoA / 2;
            if (atual) CGDisplayModeRelease(atual);
            NSDictionary *op = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES};
            NSArray *todos = CFBridgingRelease(CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)op));
            printf("oferecidos (%lu):\n", (unsigned long)todos.count);
            CGDisplayModeRef alvo2x = NULL;
            for (id m in todos) {
                CGDisplayModeRef r = (__bridge CGDisplayModeRef)m;
                printf("   %s\n", desc(r).UTF8String);
                if (CGDisplayModeGetPixelWidth(r) == alvoL && CGDisplayModeGetPixelHeight(r) == alvoA
                    && CGDisplayModeGetWidth(r) == alvoL / 2 && CGDisplayModeGetHeight(r) == alvoA / 2) alvo2x = r;
            }
            printf("ALVO %ux%u @2x: nasceu=%s oferecido=%s\n", alvoL, alvoA, nasceuNoAlvo ? "SIM" : "nao", alvo2x ? "SIM" : "nao");
            if (fixar && !nasceuNoAlvo && alvo2x) {
                CGDisplayConfigRef c = NULL;
                CGError e1 = CGBeginDisplayConfiguration(&c);
                CGError e2 = e1 == kCGErrorSuccess ? CGConfigureDisplayWithDisplayMode(c, did, alvo2x, NULL) : e1;
                CGError e3 = e2 == kCGErrorSuccess ? CGCompleteDisplayConfiguration(c, kCGConfigureForSession) : e2;
                if (e2 != kCGErrorSuccess && c) CGCancelDisplayConfiguration(c);
                usleep(500000);
                CGDisplayModeRef depois = CGDisplayCopyDisplayMode(did);
                printf("fixar 2x: begin=%d configure=%d complete=%d | agora: %s\n", e1, e2, e3, desc(depois).UTF8String);
                if (depois) CGDisplayModeRelease(depois);
            }
            codigo = nasceuNoAlvo ? 0 : 1;
            usleep((useconds_t)(segundos * 1e6));
            // `mon` sai de escopo ao sair do processo — o processo sair é o que tira o monitor.
            (void)mon;
            dispatch_semaphore_signal(pronto);
        });
        dispatch_semaphore_wait(pronto, DISPATCH_TIME_FOREVER);
        return codigo;
    }
}
