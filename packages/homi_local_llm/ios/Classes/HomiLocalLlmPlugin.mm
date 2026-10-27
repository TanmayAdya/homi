#import "HomiLocalLlmPlugin.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <mutex>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include "../../native/homi_llm.h"
#ifndef HOMI_LLAMA_TRIAL
#define HOMI_LLAMA_TRIAL 0
#endif
static NSString *const modelHash = @"9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031";
static const unsigned long long modelBytes = 639446688;
static NSString *codeName(int code) {
  switch (code) {
    case HOMI_INVALID_INPUT: return @"INVALID_INPUT";
    case HOMI_BUSY: return @"BUSY";
    case HOMI_CANCELLED: return @"CANCELLED";
    case HOMI_MODEL_MISSING: return @"MODEL_MISSING";
    case HOMI_INVALID_MODEL: return @"INVALID_MODEL";
    case HOMI_CONTEXT_LIMIT: return @"CONTEXT_LIMIT";
    case HOMI_UNSUPPORTED: return @"UNSUPPORTED";
    default: return @"FAILED";
  }
}
static FlutterError *failure(NSString *code) {
  return [FlutterError errorWithCode:code message:@"The local model operation could not finish." details:nil];
}
@interface HomiLocalLlmPlugin () <UIDocumentPickerDelegate> {
  dispatch_queue_t _worker;
  std::atomic_bool _cancelled;
  std::atomic_bool _foreground;
  std::mutex _importCommitMutex;
  std::string _importIdentifier;
}
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
@property(nonatomic, copy) NSString *operationId;
@property(nonatomic, copy) FlutterResult result;
@end
@implementation HomiLocalLlmPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  HomiLocalLlmPlugin *plugin = [[self alloc] init];
  plugin.presenter = registrar.viewController;
  plugin->_worker = dispatch_queue_create("org.safeathome.local-llm", DISPATCH_QUEUE_SERIAL);
  plugin->_cancelled = false;
  plugin->_foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"homi_local_llm" binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:channel];
  [NSNotificationCenter.defaultCenter addObserver:plugin selector:@selector(background) name:UIApplicationWillResignActiveNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:plugin selector:@selector(foreground) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)foreground { std::lock_guard<std::mutex> lock(_importCommitMutex); _foreground = true; }
- (void)background {
  { std::lock_guard<std::mutex> lock(_importCommitMutex); _foreground = false; _cancelled = true; }
  if (self.operationId) homi_llm_cancel(self.operationId.UTF8String);
  if (self.picker) { [self.picker dismissViewControllerAnimated:NO completion:nil]; self.picker = nil; [self finish:self.operationId value:failure(@"CANCELLED")]; }
  dispatch_async(_worker, ^{ homi_llm_unload(); });
}
- (NSURL *)modelURL {
  NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  return [[base URLByAppendingPathComponent:@"HomiModels" isDirectory:YES] URLByAppendingPathComponent:@"Qwen3-0.6B-Q8_0.gguf"];
}
- (NSDictionary *)status {
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.modelURL.path error:nil];
  return @{@"compiled": @(HOMI_LLAMA_TRIAL == 1), @"installed": @([attributes fileSize] == modelBytes),
    @"busy": @(self.operationId != nil || homi_llm_busy()), @"modelId": @"Qwen3-0.6B-Q8_0",
    @"runtimeId": @(homi_llm_runtime_id()), @"bytes": @(modelBytes), @"sha256": modelHash};
}
- (void)finish:(NSString *)identifier value:(id)value {
  if (!identifier || ![self.operationId isEqualToString:identifier]) return;
  FlutterResult reply = self.result; self.result = nil; self.operationId = nil;
  if (reply) reply(value);
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : nil;
  NSString *identifier = [args[@"requestId"] isKindOfClass:NSString.class] ? args[@"requestId"] : nil;
  if ([call.method isEqualToString:@"status"]) { result([self status]); return; }
  if ([call.method isEqualToString:@"cancel"]) {
    if (![[NSUUID alloc] initWithUUIDString:identifier ?: @""]) { result(failure(@"INVALID_INPUT")); return; }
    if ([identifier isEqualToString:self.operationId]) {
      { std::lock_guard<std::mutex> lock(_importCommitMutex); _cancelled = true; }
      homi_llm_cancel(identifier.UTF8String);
      if (self.picker) { [self.picker dismissViewControllerAnimated:NO completion:nil]; self.picker = nil; [self finish:identifier value:failure(@"CANCELLED")]; }
    }
    result(nil); return;
  }
  if ([call.method isEqualToString:@"unload"]) {
    if (self.operationId) {
      { std::lock_guard<std::mutex> lock(_importCommitMutex); _cancelled = true; }
      homi_llm_cancel(self.operationId.UTF8String);
    }
    dispatch_async(_worker, ^{ homi_llm_unload(); dispatch_async(dispatch_get_main_queue(), ^{ result(nil); }); }); return;
  }
  if (!HOMI_LLAMA_TRIAL) { result(failure(@"UNSUPPORTED")); return; }
  if (!_foreground) { result(failure(@"CANCELLED")); return; }
  if (self.operationId) { result(failure(@"BUSY")); return; }
  if ([call.method isEqualToString:@"deleteModel"]) {
    identifier = NSUUID.UUID.UUIDString; self.operationId = identifier; self.result = result;
    dispatch_async(_worker, ^{
      int code = homi_llm_unload(); NSError *error = nil;
      NSURL *url = self.modelURL;
      if (code == HOMI_OK && [NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSFileManager.defaultManager removeItemAtURL:url error:&error];
      dispatch_async(dispatch_get_main_queue(), ^{
        FlutterResult reply = self.result; self.result = nil; self.operationId = nil;
        reply(code != HOMI_OK || error ? failure(@"FAILED") : [self status]);
      });
    }); return;
  }
  if (![[NSUUID alloc] initWithUUIDString:identifier ?: @""]) { result(failure(@"INVALID_INPUT")); return; }
  if ([call.method isEqualToString:@"importModel"]) {
    if (args.count != 1 || !self.presenter) { result(failure(@"INVALID_INPUT")); return; }
    self.operationId = identifier; self.result = result;
    { std::lock_guard<std::mutex> lock(_importCommitMutex); _cancelled = false; _importIdentifier = identifier.UTF8String; }
    self.picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    self.picker.delegate = self; self.picker.allowsMultipleSelection = NO;
    [self.presenter presentViewController:self.picker animated:YES completion:nil]; return;
  }
  if (![call.method isEqualToString:@"generate"]) { result(FlutterMethodNotImplemented); return; }
  NSString *system = args[@"systemPrompt"], *prompt = args[@"prompt"];
  if (args.count != 3 || ![system isKindOfClass:NSString.class] || ![prompt isKindOfClass:NSString.class] ||
      [system lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [prompt lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 20000) { result(failure(@"INVALID_INPUT")); return; }
  if (![[self status][@"installed"] boolValue]) { result(failure(@"MODEL_MISSING")); return; }
  self.operationId = identifier; self.result = result; _cancelled = false;
  dispatch_async(_worker, ^{
    char output[9601]; homi_llm_metrics metrics = {};
    int code = self->_cancelled ? HOMI_CANCELLED : homi_llm_generate(identifier.UTF8String, self.modelURL.path.UTF8String, system.UTF8String, prompt.UTF8String, 1, output, sizeof(output), &metrics);
    NSString *text = code == HOMI_OK ? [[NSString alloc] initWithUTF8String:output] : nil;
    if (!self->_foreground || self->_cancelled) { code = HOMI_CANCELLED; homi_llm_unload(); }
    id value = code == HOMI_OK && text ? @{@"text": text, @"firstTokenMs": @(metrics.first_token_ms), @"totalMs": @(metrics.total_ms), @"promptTokens": @(metrics.prompt_tokens), @"outputTokens": @(metrics.output_tokens)} : failure(codeName(code));
    dispatch_async(dispatch_get_main_queue(), ^{ [self finish:identifier value:value]; });
  });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  if (controller != self.picker) return;
  self.picker = nil; [self finish:self.operationId value:failure(@"CANCELLED")];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (controller != self.picker) return;
  NSString *identifier = self.operationId; self.picker = nil;
  if (!identifier || urls.count != 1) { [self finish:identifier value:failure(@"INVALID_MODEL")]; return; }
  NSURL *source = urls.firstObject;
  dispatch_async(_worker, ^{
    BOOL security = [source startAccessingSecurityScopedResource];
    NSURL *destination = self.modelURL;
    NSURL *folder = destination.URLByDeletingLastPathComponent;
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error];
    BOOL excluded = [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error];
    for (NSURL *old in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil]) {
      if ([old.pathExtension isEqualToString:@"part"]) [NSFileManager.defaultManager removeItemAtURL:old error:nil];
    }
    NSURL *temporary = [folder URLByAppendingPathComponent:[identifier stringByAppendingString:@".part"]];
    NSInputStream *input = [NSInputStream inputStreamWithURL:source];
    NSOutputStream *output = [NSOutputStream outputStreamWithURL:temporary append:NO];
    [input open]; [output open];
    BOOL temporaryExcluded = [temporary setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error];
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    unsigned long long total = 0; uint8_t buffer[65536];
    BOOL valid = error == nil && excluded && temporaryExcluded;
    while (valid && !self->_cancelled) {
      NSInteger count = [input read:buffer maxLength:sizeof(buffer)];
      if (count < 0) { valid = NO; break; }
      if (count == 0) break;
      total += count; if (total > modelBytes) { valid = NO; break; }
      CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
      NSInteger offset = 0;
      while (offset < count) { NSInteger written = [output write:buffer + offset maxLength:count - offset]; if (written <= 0) { valid = NO; break; } offset += written; }
    }
    [input close]; [output close]; if (security) [source stopAccessingSecurityScopedResource];
    unsigned char sum[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(sum, &hash);
    NSMutableString *hex = [NSMutableString string]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", sum[i]];
    valid = valid && !self->_cancelled && total == modelBytes && [hex isEqualToString:modelHash];
    if (valid) {
      int fd = open(temporary.fileSystemRepresentation, O_RDONLY);
      valid = fd >= 0 && fsync(fd) == 0;
      if (fd >= 0) close(fd);
    }
    if (valid) {
      std::lock_guard<std::mutex> lock(self->_importCommitMutex);
      valid = !self->_cancelled && self->_foreground && self->_importIdentifier == identifier.UTF8String;
      if (valid) valid = homi_llm_unload() == HOMI_OK;
      if (valid) valid = rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
    }
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    BOOL wasCancelled = self->_cancelled;
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterResult reply = self.result;
      if (![self.operationId isEqualToString:identifier]) return;
      self.operationId = nil; self.result = nil;
      reply(valid ? [self status] : failure(wasCancelled ? @"CANCELLED" : @"INVALID_MODEL"));
    });
  });
}
@end
