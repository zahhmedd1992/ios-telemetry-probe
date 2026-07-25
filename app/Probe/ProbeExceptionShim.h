#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, trapping any Objective-C exception it raises.
///
/// WHY THIS FILE EXISTS
///
/// Swift cannot catch an NSException. `do/catch` handles Swift `Error`s only, so
/// an ObjC framework that calls `[NSException raise:]` terminates the process —
/// no Swift construct stops it. This app's whole job is to poke at every
/// permission-gated framework on the device, which is precisely the activity
/// most likely to provoke one.
///
/// Confirmed on device 2026-07-24: `HKHealthStore requestAuthorizationToShareTypes:readTypes:`
/// raised from `-[HKHealthStoreImplementation _throwIfAuthorizationDisallowedForSharing:types:]`
/// and killed the app with SIGABRT before a single section was reported.
///
/// Returns YES if the block completed, NO if it raised. On NO, `outReason`
/// receives "<exception name>: <reason>" so the probe can REPORT the throw
/// instead of dying from it — a caught exception is a finding, not a failure.
BOOL ProbeCatchNSException(void (NS_NOESCAPE ^block)(void),
                           NSString * _Nullable * _Nullable outReason);

NS_ASSUME_NONNULL_END
