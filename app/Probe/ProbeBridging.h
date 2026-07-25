// Objective-C surface exposed to Swift.
// Kept deliberately tiny — the only reason this target is mixed-language is
// that Swift cannot catch an NSException, and a probe that pokes at every
// framework on the device will eventually provoke one.
#import "ProbeExceptionShim.h"
