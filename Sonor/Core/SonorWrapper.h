#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SonorWrapper : NSObject

- (instancetype)initWithModelPath:(NSString *)modelPath;
- (NSString *)transcribeAudioBuffer:(float *)samples count:(int)count language:(NSString *)language initialPrompt:(nullable NSString *)initialPrompt;

/// Stops the running transcription. The call returns at once, and the transcription returns
/// an empty string soon after. Each new transcription clears the request again.
- (void)requestAbort;

@end

NS_ASSUME_NONNULL_END
