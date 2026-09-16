#import "SonorWrapper.h"
#import "sonor.h"
#import <Metal/Metal.h>
#include <atomic>

@interface SonorWrapper () {
    struct sonor_context * ctx;
    /// The live preview runs on the same context as the final transcription. When the user
    /// stops talking, the preview must give the context back without waiting for its result.
    std::atomic<bool> abortRequested;
}
@end

static bool sonor_wrapper_should_abort(void * userData) {
    return ((std::atomic<bool> *) userData)->load(std::memory_order_relaxed);
}

@implementation SonorWrapper


- (instancetype)initWithModelPath:(NSString *)modelPath {
    self = [super init];
    if (self) {
        bool use_gpu = true;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        
        if (!device) {
            use_gpu = false;
        } else {
            NSString *name = [device.name lowercaseString];
            if ([name containsString:@"software"] || [name containsString:@"llvm"] || [name containsString:@"paravirtual"]) {
                use_gpu = false;
            }
        }
        
        abortRequested.store(false, std::memory_order_relaxed);

        struct sonor_context_params cparams = sonor_context_default_params();
        cparams.use_gpu = use_gpu;
        
        ctx = sonor_init_from_file_with_params([modelPath UTF8String], cparams);
        if (!ctx) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (ctx) {
        sonor_free(ctx);
    }
}

- (void)requestAbort {
    abortRequested.store(true, std::memory_order_relaxed);
}

- (NSString *)transcribeAudioBuffer:(float *)samples count:(int)count language:(NSString *)language initialPrompt:(NSString *)initialPrompt {
    if (!ctx) return @"";

    // A request that arrived between two transcriptions must not stop this one.
    abortRequested.store(false, std::memory_order_relaxed);

    struct sonor_full_params params = sonor_full_default_params(SONOR_SAMPLING_GREEDY);
    params.print_progress   = false;
    params.print_special    = false;
    params.print_realtime   = false;
    params.print_timestamps = false;
    
    // Set language from parameter, defaulting to "auto" if not provided
    if (language && [language length] > 0) {
        params.language = strdup([language UTF8String]);
    } else {
        params.language = strdup("auto");
    }
    
    if (initialPrompt && [initialPrompt length] > 0) {
        params.initial_prompt = strdup([initialPrompt UTF8String]);
    }
    
    params.n_threads        = 4;
    params.offset_ms        = 0;
    params.no_context       = true;

    params.abort_callback           = sonor_wrapper_should_abort;
    params.abort_callback_user_data = &abortRequested;
    
    int ret = sonor_full(ctx, params, samples, count);
    
    if (params.language) {
        free((void *)params.language);
    }
    
    if (params.initial_prompt) {
        free((void *)params.initial_prompt);
    }
    
    if (ret != 0) {
        return @"";
    }
    
    (void)sonor_full_lang_id(ctx);
    
    const int n_segments = sonor_full_n_segments(ctx);
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < n_segments; ++i) {
        const char *text = sonor_full_get_segment_text(ctx, i);
        if (text) {
            NSString *segmentText = [NSString stringWithUTF8String:text];
            if (segmentText) {
                [result appendString:segmentText];
            }
        }
    }
    
    return [result copy];
}

@end
