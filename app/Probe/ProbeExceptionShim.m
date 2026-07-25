#import "ProbeExceptionShim.h"

BOOL ProbeCatchNSException(void (NS_NOESCAPE ^block)(void),
                           NSString * _Nullable * _Nullable outReason) {
    @try {
        block();
        return YES;
    }
    @catch (NSException *e) {
        if (outReason) {
            NSString *name = e.name ?: @"NSException";
            NSString *why  = e.reason ?: @"(no reason given)";
            *outReason = [NSString stringWithFormat:@"%@: %@", name, why];
        }
        return NO;
    }
    @catch (id other) {
        if (outReason) {
            *outReason = [NSString stringWithFormat:@"non-NSException throw: %@", other];
        }
        return NO;
    }
}
