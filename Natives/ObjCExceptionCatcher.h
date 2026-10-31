#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSException *_Nullable AMECatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
