#import <Foundation/Foundation.h>
#import "WCGroupBarManager.h"

__attribute__((constructor))
static void WCGroupBarInit(void) {
    @autoreleasepool {
        [[WCGroupBarManager sharedManager] install];
    }
}
