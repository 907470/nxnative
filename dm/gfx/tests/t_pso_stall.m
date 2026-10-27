// A compile that does not return (GitHub issue #294: a base Apple's compiler cannot build) holds back only the file of its own flush period (ArchEpoch in nvn_mtl.m). A compiler
// that holds one pixel shader's compile stands in for it. Checks, while it is held: the prebuild hands out every pair and builds the others;
// a draw's compile goes through; a flush of a later period writes its file. Once released: its period is written, the prebuild finishes and stamps, nothing is left to write
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, want, ...) do { uint64_t w = (want), g = (__VA_ARGS__); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)

// Holds the compile whose pixel function is named "hold" until released
@interface HoldCompiler : NSObject { @public id<MTL4Compiler> compiler; dispatch_semaphore_t entered, release; } @end
@implementation HoldCompiler
- (id)forwardingTargetForSelector:(SEL)selector { return compiler; }
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d compilerTaskOptions:(MTL4CompilerTaskOptions *)opts error:(NSError **)error {
    MTL4FunctionDescriptor *f = d.fragmentFunctionDescriptor;
    if ([f isKindOfClass:[MTL4LibraryFunctionDescriptor class]] && [((MTL4LibraryFunctionDescriptor *)f).name isEqualToString:@"hold"]) {
        dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    }
    return [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:opts error:error];
}
@end
static int sh(NSString *cmd) { int r = system(cmd.UTF8String); return WIFEXITED(r) ? WEXITSTATUS(r) : -1; }
static void put(NSString *path, NSString *text) { [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static int lib(NSString *dir, NSString *name, NSString *src) {   // <dir>/<name>.metallib from MSL, with the SDK's compiler
    put([NSString stringWithFormat:@"%@/%@.metal", dir, name], src);
    return sh([NSString stringWithFormat:@"cd %@ && xcrun -sdk macosx metal -c %@.metal -o %@.air && xcrun -sdk macosx metallib %@.air -o %@.metallib && rm %@.metal %@.air", dir, name, name, name, name, name, name]);
}
static NSUInteger files(NSString *dir) { return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mtl4a'"]].count; }
static int until(int (^cond)(void), double seconds) { uint64_t t0 = bp_now(); while (!cond()) { if (bp_now() - t0 > seconds * 1e9) return 0; usleep(10000); } return 1; }

int main(void) { @autoreleasepool {
    char tmp[] = "/tmp/t_pso_stall.XXXXXX"; if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    NSString *arch = [root stringByAppendingPathComponent:@"archive"];
    NSString *v = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n";
    NSString *f = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 %@() { return float4(%d, %d, %d.0 / 65536.0, 1); }\n";
    [NSFileManager.defaultManager createDirectoryAtPath:msl withIntermediateDirectories:YES attributes:nil error:nil];
    int pid = getpid() & 0xffff;
    if (lib(msl, @"v1_bp", v) || lib(msl, @"f1_b", [NSString stringWithFormat:f, @"hold", 1, 0, pid]) || lib(msl, @"f2_b", [NSString stringWithFormat:f, @"main0", 0, 1, pid]) ||
        lib(msl, @"f3_b", [NSString stringWithFormat:f, @"main0", 1, 1, pid]) || lib(msl, @"f4_b", [NSString stringWithFormat:f, @"main0", 0, 0, pid])) {
        printf("t_pso_stall: no Metal compiler (xcrun metal), not run\n"); return 0; }
    put([msl stringByAppendingPathComponent:@"v1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
    put([msl stringByAppendingPathComponent:@"f1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"hold\"}", DMSH_CHAIN]);
    for (NSString *k in @[@"f2", @"f3", @"f4"]) put([msl stringByAppendingFormat:@"/%@_b.json", k], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\"}", DMSH_CHAIN]);
    put([tables stringByAppendingPathComponent:@"shader_map.tsv"], @"# empty\n");
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf1\nv1\tf2\nv1\tf3\n");
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_MANIFEST", "off", 1);
    mtl_init(); pso4_init();
    if (!g_comp4 || !g_arch_cap) { printf("t_pso_stall: no Metal 4 compiler, not run\n"); return 0; }

    ArchEpoch *ep1 = g_ep; HoldCompiler *hold = [HoldCompiler new]; hold->compiler = ep1->comp;
    hold->entered = dispatch_semaphore_create(0); hold->release = dispatch_semaphore_create(0); ep1->comp = (id<MTL4Compiler>)hold;
    EXPECT("three pairs", 3, pso_prebuild(2, 0, QOS_CLASS_USER_INITIATED));
    EXPECT("held: the compile of f1 entered", 0, dispatch_semaphore_wait(hold->entered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    EXPECT("held: every pair handed out", 1, until(^{ return (int)(atomic_load(&g_pre_next) >= 3); }, 10));
    EXPECT("held: the other pairs built", 1, until(^{ return (int)(g_pre_done == 2); }, 10));
    EXPECT("held: the prebuild not done", 1, g_pre_running);

    // a flush hands the held period over and returns; a draw's compile in the next period goes through, and that period's flush writes its file
    arch_flush();
    EXPECT("held: the flush began a new period", 1, g_ep != ep1);
    MTL4RenderPipelineDescriptor *m = pre_desc(@"v1", @"f4", 0);
    EXPECT("held: a descriptor for the draw", 1, m != nil);
    dispatch_group_t draw = dispatch_group_create(); __block id drawn = nil;
    dispatch_group_async(draw, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { NSError *e = nil; drawn = arch_capture(m, &e, 0); } });
    EXPECT("held: a draw's compile returns", 0, dispatch_group_wait(draw, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    EXPECT("held: a draw's compile built", 1, drawn != nil);
    arch_flush();
    EXPECT("held: the later period's file written", 1, until(^{ return (int)(files(arch) == 1); }, 10));

    // released: the held period is written, the prebuild finishes and stamps
    dispatch_semaphore_signal(hold->release);
    EXPECT("released: the prebuild finished", 1, until(^{ return (int)!g_pre_running; }, 30));
    EXPECT("released: every pair built", 3, g_pre_built);
    EXPECT("released: none failed", 0, g_pre_failed);
    EXPECT("released: the held period's file written", 2, files(arch));
    EXPECT("released: stamped", 1, [NSFileManager.defaultManager fileExistsAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"]]);
    EXPECT("released: nothing left to write", 0, g_arch_new);
    ep1->comp = hold->compiler;

    // every base is in the files
    NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:arch error:nil]) if ([n hasSuffix:@".mtl4a"])
        [open addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:[arch stringByAppendingPathComponent:n]] error:nil]];
    int found = 0;
    for (NSString *k in @[@"f1", @"f2", @"f3", @"f4"]) @autoreleasepool {
        MTL4RenderPipelineDescriptor *d = pre_desc(@"v1", k, 0);
        for (id<MTL4Archive> a in open) if ([a newRenderPipelineStateWithDescriptor:d error:nil]) { found++; break; }
    }
    EXPECT("every base in the files", 4, found);
    // a base whose period is written and gone still specializes (the draws keep bases for the whole run)
    MTL4RenderPipelineDescriptor *s = (MTL4RenderPipelineDescriptor *)[drawn newRenderPipelineDescriptorForSpecialization];
    s.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; s.colorAttachments[0].writeMask = MTLColorWriteMaskAll; s.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
    NSError *se = nil;
    EXPECT("a base of a written period specializes", 1, [g_comp4 newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:drawn error:&se] != nil);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("t_pso_stall: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
