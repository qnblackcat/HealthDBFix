// Debug-only (compiled when HEALTHDBFIX_DEBUG=1, see Makefile). Kept in its own file because Logos
// ignores #if and would register this hook even in release builds.
#import <Foundation/Foundation.h>

void HDBFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

@interface HDCloudSyncOperation : NSObject
@property (nonatomic, strong) NSDate *hdbf_start;
@end

@interface HDCloudSyncPullChangeRecordOperation : HDCloudSyncOperation
@end

// Cloud sync timing, to see whether healthd is busy with iCloud while Health waits on it.
%hook HDCloudSyncOperation

%property (nonatomic, strong) NSDate *hdbf_start;

- (void)start {
	self.hdbf_start = [NSDate date];
	if ([self isKindOfClass:%c(HDCloudSyncPullChangeRecordOperation)]) {
		HDBFLog(@"cloud pull start %p", self);
	}
	%orig;
}

- (void)finishWithSuccess:(BOOL)success error:(NSError *)error {
	NSDate *start = self.hdbf_start;
	NSTimeInterval duration = start ? -start.timeIntervalSinceNow : -1;
	BOOL isPull = [self isKindOfClass:%c(HDCloudSyncPullChangeRecordOperation)];
	if (isPull || duration >= 5 || !success) {
		HDBFLog(@"cloud %@ %p finished success=%d in %.1fs%@",
			NSStringFromClass([self class]), self, success, duration,
			error ? [NSString stringWithFormat:@" error=%@", error] : @"");
	}
	%orig;
}

%end
