#import <Foundation/Foundation.h>
#import <dlfcn.h>
#if HEALTHDBFIX_DEBUG
#import <fcntl.h>
#import <os/lock.h>
#import <sys/stat.h>
#import <unistd.h>
#endif

// healthd crash (iOS 17.0 / 17.1.1): -[HDSourceOrderManager createSourceOrdersWithCodables:error:] skips a
// synced source order whose data type code fails _HKValidDataTypeCode(), but its cleanup path then
// calls +[HKObjectType dataTypeWithCode:] with that same code, which raises
// "invalid data type code (%ld)" -> abort. The sync transaction rolls back, so the same change (from
// the paired Watch or from iCloud) is received again on every launch -> crash loop.
//
// Debug logging/self-test/timing code only exists when built with HEALTHDBFIX_DEBUG=1 (see Makefile).
//
// Two layers:
//  1. receiveSyncObjects: drop source orders with invalid codes before Apple's code sees them.
//  2. _dataTypeWithCode:expectedClass: return nil for invalid codes (the caller already handles nil).

@interface HKObjectType : NSObject
#if HEALTHDBFIX_DEBUG
+ (id)dataTypeWithCode:(NSInteger)code;
#endif
@end

@interface HDCodableObjectTypeSourceOrder : NSObject
- (int64_t)decodedDataTypeCode;
#if HEALTHDBFIX_DEBUG
- (id)sourceUUIDs;
#endif
@end

@interface HDLogicalSourceOrderSyncEntity : NSObject
@end

static BOOL (*HKValidDataTypeCode)(NSInteger code);

#if HEALTHDBFIX_DEBUG

// oslog on the device can't decode message bodies, so also append to a file.
static int logFD = -1;
static NSString *logPath;
static const off_t kMaxLogSize = 2 * 1024 * 1024;

void HDBFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void HDBFLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	NSLog(@"[HealthDBFix] %@", message);
	if (logFD < 0) return;

	static NSDateFormatter *formatter;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		formatter = [NSDateFormatter new];
		formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	});
	static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
	os_unfair_lock_lock(&lock);
	NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [formatter stringFromDate:[NSDate date]], getpid(), message];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	write(logFD, data.bytes, data.length);
	os_unfair_lock_unlock(&lock);
}

static void openLogFile(void) {
	NSArray<NSString *> *dirs = @[
		NSTemporaryDirectory() ?: @"",
		@"/var/mobile/Library/Health",
		@"/var/mobile/Library/Logs",
		@"/var/mobile/tmp",
		@"/tmp",
	];
	for (NSString *dir in dirs) {
		if (!dir.length) continue;
		NSString *path = [dir stringByAppendingPathComponent:@"HealthDBFix.log"];
		int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
		if (fd < 0) continue;
		struct stat st;
		if (fstat(fd, &st) == 0 && st.st_size > kMaxLogSize) ftruncate(fd, 0);
		logFD = fd;
		logPath = path;
		return;
	}
}

// sourceUUIDs is serialized as concatenated 16-byte UUIDs.
static NSString *describeSourceUUIDs(id value) {
	if ([value isKindOfClass:[NSData class]] && [(NSData *)value length] % 16 == 0) {
		NSData *data = value;
		NSMutableArray<NSString *> *uuids = [NSMutableArray array];
		for (NSUInteger offset = 0; offset < data.length; offset += 16) {
			uuid_t bytes;
			[data getBytes:bytes range:NSMakeRange(offset, 16)];
			[uuids addObject:[[NSUUID alloc] initWithUUIDBytes:bytes].UUIDString];
		}
		return [uuids componentsJoinedByString:@", "];
	}
	return [value description];
}

#endif // HEALTHDBFIX_DEBUG

static BOOL isInvalidCode(NSInteger code) {
	return HKValidDataTypeCode && !HKValidDataTypeCode(code);
}

%hook HKObjectType

+ (id)_dataTypeWithCode:(NSInteger)code expectedClass:(Class)expectedClass {
	// Pre-check instead of @try/@catch: on 17.1.1 the raise happens before the internal
	// os_unfair_lock is taken, but that is not guaranteed on other versions.
	if (isInvalidCode(code)) {
#if HEALTHDBFIX_DEBUG
		NSArray<NSString *> *stack = [NSThread callStackSymbols];
		NSRange range = NSMakeRange(0, MIN((NSUInteger)8, stack.count));
		HDBFLog(@"invalid data type code %ld (0x%lx), expectedClass=%@ -> returning nil\n%@",
			(long)code, (long)code, NSStringFromClass(expectedClass),
			[[stack subarrayWithRange:range] componentsJoinedByString:@"\n"]);
#endif
		return nil;
	}
	return %orig;
}

%end

%hook HDLogicalSourceOrderSyncEntity

// version is an 8-byte struct passed in one register, so uint64_t matches the ABI.
+ (NSInteger)receiveSyncObjects:(NSArray *)objects version:(uint64_t)version syncStore:(id)syncStore profile:(id)profile error:(NSError **)error {
	NSMutableArray *kept = [NSMutableArray arrayWithCapacity:objects.count];
	for (id object in objects) {
		if ([object respondsToSelector:@selector(decodedDataTypeCode)]) {
			int64_t code = [object decodedDataTypeCode];
			if (isInvalidCode(code)) {
#if HEALTHDBFIX_DEBUG
				NSString *sources = [object respondsToSelector:@selector(sourceUUIDs)] ? describeSourceUUIDs([object sourceUUIDs]) : @"?";
				HDBFLog(@"dropping source order with invalid code %lld (0x%llx)\n  sources: %@\n  codable: %@",
					code, code, sources, object);
#endif
				continue;
			}
		}
		[kept addObject:object];
	}
#if HEALTHDBFIX_DEBUG
	HDBFLog(@"receiveSyncObjects: %lu source orders, %lu dropped, version=0x%llx, syncStore=%@ %@",
		(unsigned long)objects.count, (unsigned long)(objects.count - kept.count), version,
		NSStringFromClass([syncStore class]), syncStore);
#endif
	NSInteger result = %orig(kept, version, syncStore, profile, error);
#if HEALTHDBFIX_DEBUG
	HDBFLog(@"receiveSyncObjects -> %ld", (long)result);
#endif
	return result;
}

%end

#if HEALTHDBFIX_DEBUG

// Proves the hook works on this device/iOS without waiting for a bad sync: the first invalid code
// must come back as nil instead of raising.
static void selfTest(void) {
	if (!HKValidDataTypeCode) {
		HDBFLog(@"self-test skipped: _HKValidDataTypeCode not found, hooks are inactive");
		return;
	}
	NSInteger code = 0;
	while (code < 4096 && HKValidDataTypeCode(code)) code++;
	Class cls = NSClassFromString(@"HKObjectType");
	@try {
		id type = [cls dataTypeWithCode:code];
		HDBFLog(@"self-test %@: dataTypeWithCode:%ld (first invalid code) -> %@, no exception",
			type ? @"FAILED" : @"OK", (long)code, type);
	} @catch (NSException *exception) {
		HDBFLog(@"self-test FAILED: dataTypeWithCode:%ld raised %@: %@", (long)code, exception.name, exception.reason);
	}
}

#endif // HEALTHDBFIX_DEBUG

%ctor {
	HKValidDataTypeCode = (BOOL (*)(NSInteger))dlsym(RTLD_DEFAULT, "_HKValidDataTypeCode");
#if HEALTHDBFIX_DEBUG
	openLogFile();
	HDBFLog(@"loaded %s in %@ (pid %d), _HKValidDataTypeCode=%p, log=%@",
		HEALTHDBFIX_VERSION, [NSProcessInfo processInfo].processName, getpid(), HKValidDataTypeCode, logPath);
#endif
	%init;
#if HEALTHDBFIX_DEBUG
	selfTest();
#endif
}
