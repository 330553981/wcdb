/*
 * Tencent is pleased to support the open source community by making
 * WCDB available.
 *
 * Copyright (C) 2017 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the BSD 3-Clause License (the "License"); you may not use
 * this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 *       https://opensource.org/licenses/BSD-3-Clause
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "CoreConst.h"
#import "TestCase.h"
#import <thread>

@interface ThreadTests : TableTestCase

@property (nonatomic, readonly) NSTimeInterval delayForTolerance;

@property (nonatomic, readonly) int maxConcurrency;

@end

@implementation ThreadTests

- (NSTimeInterval)delayForTolerance
{
    return 2;
}

- (int)maxConcurrency
{
    return std::max<int>(WCDB::HandlePoolMaxAllowedNumberOfHandles, std::thread::hardware_concurrency());
}

- (void)test_feature_read_concurrency
{
    // trigger table initialization
    TestCaseAssertTrue([self createTable]);

    __block NSDate* read1Begin;
    __block NSDate* read2Begin;
    __block NSDate* read1End;
    __block NSDate* read2End;
    [self.dispatch async:^{
        // Acquire read transaction. Note that it's not recommended in production environment.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginDeferred()]);
        TestCaseAssertTrue([self.database execute:WCDB::StatementSelect().select(1)]);
        read1Begin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        read1End = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch async:^{
        // Acquire read transaction. Note that it's not recommended in production environment.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginDeferred()]);
        TestCaseAssertTrue([self.database execute:WCDB::StatementSelect().select(1)]);
        read2Begin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        read2End = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch waitUntilDone];

    // Contains intersection
    TestCaseAssertTrue([read1End compare:read2Begin] == NSOrderedDescending
                       && [read2End compare:read1Begin] == NSOrderedDescending);
}

- (void)test_feature_read_and_write_concurrency
{
    // trigger table initialization
    TestCaseAssertTrue([self createTable]);

    __block NSDate* readBegin;
    __block NSDate* writeBegin;
    __block NSDate* readEnd;
    __block NSDate* writeEnd;
    [self.dispatch async:^{
        // Acquire read transaction. Note that it's not recommended in production environment.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginDeferred()]);
        TestCaseAssertTrue([self.database execute:WCDB::StatementSelect().select(1)]);
        readBegin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        readEnd = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch async:^{
        // Acquire write transaction.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginImmediate()]);
        writeBegin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        writeEnd = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch waitUntilDone];

    // Contains intersection
    TestCaseAssertTrue([readEnd compare:writeBegin] == NSOrderedDescending
                       && [writeEnd compare:readBegin] == NSOrderedDescending);
}

- (void)test_feature_write_serial
{
    // trigger table initialization
    TestCaseAssertTrue([self createTable]);

    __block NSDate* write1Begin;
    __block NSDate* write2Begin;
    __block NSDate* write1End;
    __block NSDate* write2End;
    [self.dispatch async:^{
        // Acquire write transaction.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginImmediate()]);
        write1Begin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        write1End = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch async:^{
        // Acquire write transaction.
        TestCaseAssertTrue([self.database execute:WCDB::StatementBegin().beginImmediate()]);
        write2Begin = [NSDate date];
        [NSThread sleepForTimeInterval:self.delayForTolerance];
        write2End = [NSDate date];
        TestCaseAssertTrue([self.database execute:WCDB::StatementRollback().rollback()]);
    }];
    [self.dispatch waitUntilDone];

    // No intersection
    TestCaseAssertTrue([write1Begin compare:write2End] == NSOrderedDescending
                       || [write2Begin compare:write1End] == NSOrderedDescending);
}

- (void)test_feature_subthread_checkpoint_when_idled
{
    // trigger subthread checkpoint
    TestCaseAssertTrue([self createTable]);

    TestCaseAssertOptionalFalse([self.database isAlreadyCheckpointed]);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForNonCritical + self.delayForTolerance];

    TestCaseAssertOptionalFalse([self.database isAlreadyTruncateCheckpointed]);
    TestCaseAssertOptionalTrue([self.database isAlreadyCheckpointed]);
}

- (void)test_feature_subthread_checkpoint_when_meet_frames_threshold
{
    TestCaseAssertTrue([self createTable]);

    TestCaseObject* object = [self.random autoIncrementTestCaseObject];

    while (YES) {
        auto optionalNumberOfWalFrames = [self.database getNumberOfWalFrames];
        TestCaseAssertFalse(optionalNumberOfWalFrames.failed());
        if (optionalNumberOfWalFrames.value() >= WCDB::CheckpointQueueFramesThresholdForCritical) {
            break;
        }
        TestCaseAssertTrue([self.table insertObject:object]);
    }

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForCritical + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyCheckpointed);
}

- (void)test_feature_subthread_checkpoint_when_meet_truncate_threshold
{
    TestCaseAssertTrue([self createTable]);

    TestCaseObject* object = [self.random autoIncrementTestCaseObject];

    while (YES) {
        auto optionalNumberOfWalFrames = [self.database getNumberOfWalFrames];
        TestCaseAssertFalse(optionalNumberOfWalFrames.failed());
        if (optionalNumberOfWalFrames.value() >= WCDB::CheckpointFramesThresholdForTruncating) {
            break;
        }
        TestCaseAssertTrue([self.table insertObject:object]);
    }

    TestCaseAssertOptionalFalse(self.database.isAlreadyTruncateCheckpointed);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForCritical + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyTruncateCheckpointed);
}

- (void)test_feature_retry_subthread_checkpoint_when_failed
{
    TestCaseAssertTrue([self createTable]);

    TestCaseObject* object = [self.random autoIncrementTestCaseObject];

    TestCaseAssertTrue([self.table insertObject:object]);
    auto optionalNumberOfWalFrames = [self.database getNumberOfWalFrames];
    TestCaseAssertFalse(optionalNumberOfWalFrames.failed());
    TestCaseAssertTrue(optionalNumberOfWalFrames.value() < WCDB::CheckpointQueueFramesThresholdForCritical)

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [self.database blockade];
    [WCTDatabase simulateIOError:WCTSimulateWriteIOError];
    [self.database unblockade];

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForNonCritical + self.delayForTolerance];

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [self.database blockade];
    [WCTDatabase simulateIOError:WCTSimulateNoneIOError];
    [self.database unblockade];

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForRetryingAfterFailure + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyCheckpointed);
}

- (void)test_feature_closed_database_will_not_perform_subthread_checkpoint
{
    // trigger subthread checkpoint
    TestCaseAssertTrue([self createTable]);

    TestCaseObject* object = [self.random autoIncrementTestCaseObject];

    while (YES) {
        auto optionalNumberOfWalFrames = [self.database getNumberOfWalFrames];
        TestCaseAssertFalse(optionalNumberOfWalFrames.failed());
        if (optionalNumberOfWalFrames.value() >= WCDB::CheckpointFramesThresholdForTruncating) {
            break;
        }
        TestCaseAssertTrue([self.table insertObject:object]);
    }

    auto fileSizeBefore = [self.fileManager attributesOfItemAtPath:self.database.walPath error:nil].fileSize;
    TestCaseAssertTrue(fileSizeBefore > 0);

    [self.database close];
    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForCritical + self.delayForTolerance];
    auto fileSizeAfter = [self.fileManager attributesOfItemAtPath:self.database.walPath error:nil].fileSize;
    TestCaseAssertTrue(fileSizeAfter > 0);
}

- (void)test_feature_threaded_handle
{
    __block int handleCount = 0;
    [self.database
           setConfig:^BOOL(WCTHandle*) {
               ++handleCount;
               return YES;
           }
    withUninvocation:nil
             forName:self.testName];
    {
        WCTHandle* handle1 = [self.database getHandle];
        TestCaseAssertTrue([handle1 validate]);
        WCTHandle* handle2 = [self.database getHandle];
        TestCaseAssertTrue([handle2 validate]);
        WCTHandle* handle3 = [self.database getHandle];
        TestCaseAssertTrue([handle3 validate]);

        [handle1 invalidate];
        [handle2 invalidate];
        [handle3 invalidate];
    }
    TestCaseAssertEqual(handleCount, 1);
}

- (void)test_feature_transactioned_handle
{
    BOOL result = [self.database runTransaction:^BOOL(WCTHandle* _Nonnull) {
        TestCaseAssertTrue([self.database isInTransaction]);
        WCTHandle* handle = [self.database getHandle];
        TestCaseAssertTrue([handle isInTransaction]);
        return YES;
    }];
    TestCaseAssertTrue(result);
}

- (void)test_feature_threaded_transactioned_handle
{
    TestCaseAssertTrue([self.database beginTransaction]);

    TestCaseResult* began = [TestCaseResult no];
    TestCaseResult* tested = [TestCaseResult no];
    [self.dispatch async:^{
        WCTHandle* handle = [self.database getHandle];
        TestCaseAssertFalse([handle isInTransaction]);
        // it will not reuse transactioned handle.
        TestCaseAssertTrue([handle validate]);
        [began makeYES];
        while ([tested isNO])
            ;
        [handle invalidate];
    }];

    while ([began isNO])
        ;

    // it will reuse transactioned handle.
    TestCaseAssertTrue([self.database isInTransaction]);
    [tested makeYES];
    [self.database rollbackTransaction];
}

- (void)test_feature_max_concurrency
{
    NSCondition* condition = [[NSCondition alloc] init];
    __block int currentConcurrency = 0;
    for (int i = 0; i < self.maxConcurrency; ++i) {
        [self.dispatch async:^{
            WCTHandle* handle = nil;
            @synchronized(self) {
                handle = [self.database getHandle];
            }
            TestCaseAssertTrue([handle validate]);
            [condition lock];
            ++currentConcurrency;
            [condition wait];
            [condition unlock];
            [handle invalidate];
        }];
    }

    do {
        BOOL prepared = NO;
        [condition lock];
        prepared = currentConcurrency == self.maxConcurrency;
        [condition unlock];
        if (prepared) {
            break;
        }
    } while (YES);

    TestCaseAssertFalse([[self.database getHandle] validate]);
    [condition broadcast];
    [self.dispatch waitUntilDone];
}

- (void)test_feature_checkpoint_while_notice_recover_wal
{
    // avoid auto subthread checkpoint
    [self.database removeCheckpointConfig];
    TestCaseAssertTrue([self.database truncateCheckpoint]);

    // trigger subthread checkpoint
    TestCaseAssertTrue([self createTable]);

    [self.database close];

    TestCaseResult* tested = [TestCaseResult no];
    [WCTDatabase globalTraceError:^(WCTError* error) {
        if (error.level == WCTErrorLevelIgnore
            && error.code == WCTErrorCodeNotice
            && error.extendedCode == WCTErrorExtendedCodeNoticeRecoverWal) {
            [tested makeYES];
        }
    }];

    // trigger notice recover wal
    TestCaseAssertTrue([self.database canOpen]);
    TestCaseAssertResultYES(tested);

    [WCTDatabase globalTraceError:nil];

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForNonCritical + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyCheckpointed);
}

- (void)test_feature_busy_retry
{
    TestCaseResult* began = [TestCaseResult no];
    TestCaseResult* rollbacked = [TestCaseResult no];
    TestCaseResult* tested = [TestCaseResult no];
    [self.dispatch async:^{
        TestCaseAssertTrue([self.database beginTransaction]);
        [began makeYES];

        [NSThread sleepForTimeInterval:1];
        TestCaseAssertResultNO(tested);
        [rollbacked makeYES];
        [self.database rollbackTransaction];
    }];

    while ([began isNO]) {
    }

    TestCaseAssertTrue([self.database beginTransaction]);
    TestCaseAssertResultYES(rollbacked);
    [tested makeYES];
    [self.database rollbackTransaction];
    [self.dispatch waitUntilDone];
}

- (void)test_feature_busy_retry_main_thread_timeout
{
    TestCaseResult* began = [TestCaseResult no];
    TestCaseResult* rollbacked = [TestCaseResult no];
    TestCaseResult* tested = [TestCaseResult no];
    [self.dispatch async:^{
        TestCaseAssertTrue([self.database beginTransaction]);
        [began makeYES];

        [NSThread sleepForTimeInterval:WCDB::BusyRetryTimeOutForMainThread - self.delayForTolerance];
        TestCaseAssertResultNO(tested);

        [NSThread sleepForTimeInterval:2 * self.delayForTolerance];
        TestCaseAssertResultYES(tested);

        [rollbacked makeYES];
        [self.database rollbackTransaction];
    }];

    while ([began isNO]) {
    }

    weakify(self);
    [WCTDatabase globalTraceError:^(WCTError* error) {
        strongify_or_return(self);
        if (error.code == WCTErrorCodeBusy
            && error.level == WCTErrorLevelError
            && [error.path isEqualToString:self.database.path]
            && error.tag == self.database.tag
            && [error.sql isEqualToString:@"BEGIN IMMEDIATE"]) {
            [tested makeYES];
        }
    }];

    TestCaseAssertFalse([self.database beginTransaction]);
    TestCaseAssertResultNO(rollbacked);
    [self.database rollbackTransaction];
    [self.dispatch waitUntilDone];
}

- (void)test_feature_busy_retry_sub_thread_timeout
{
    TestCaseResult* began = [TestCaseResult no];
    TestCaseResult* rollbacked = [TestCaseResult no];
    TestCaseResult* tested = [TestCaseResult no];
    [self.dispatch async:^{
        TestCaseAssertTrue([self.database beginTransaction]);
        [began makeYES];

        [NSThread sleepForTimeInterval:WCDB::BusyRetryTimeOutForSubThread - self.delayForTolerance];
        TestCaseAssertResultNO(tested);

        [NSThread sleepForTimeInterval:2 * self.delayForTolerance];
        TestCaseAssertResultYES(tested);

        [rollbacked makeYES];
        [self.database rollbackTransaction];
    }];

    [self.dispatch async:^{
        while ([began isNO]) {
        }

        weakify(self);
        [WCTDatabase globalTraceError:^(WCTError* error) {
            strongify_or_return(self);
            if (error.code == WCTErrorCodeBusy
                && error.level == WCTErrorLevelError
                && [error.path isEqualToString:self.database.path]
                && error.tag == self.database.tag
                && [error.sql isEqualToString:@"BEGIN IMMEDIATE"]) {
                [tested makeYES];
            }
        }];

        TestCaseAssertFalse([self.database beginTransaction]);
        TestCaseAssertResultNO(rollbacked);
        [self.database rollbackTransaction];
    }];
    [self.dispatch waitUntilDone];
}

- (void)test_feature_sub_thread_checkpoint_for_attached
{
    TestCaseAssertTrue([self createTable]);

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForNonCritical + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyCheckpointed);

    NSString* toAttachPath = [self.path stringByAppendingString:@"_to_attach"];
    NSString* attachedName = @"test_attached";
    WCTDatabase* toAttachDatabase = [[WCTDatabase alloc] initWithPath:toAttachPath];
    TestCaseAssertTrue([toAttachDatabase execute:WCDB::StatementAttach().attach(self.path).as(attachedName)]);

    // trigger subthread checkpoint for attached
    TestCaseObject* object = [self.random autoIncrementTestCaseObject];

    WCTInsert* insert = [[[toAttachDatabase prepareInsert] intoTable:self.tableName] value:object];
    insert.statement.schema(attachedName);
    TestCaseAssertTrue([insert execute]);

    TestCaseAssertOptionalFalse(self.database.isAlreadyCheckpointed);

    [NSThread sleepForTimeInterval:WCDB::CheckpointQueueDelayForNonCritical + self.delayForTolerance];

    TestCaseAssertOptionalTrue(self.database.isAlreadyCheckpointed);
}

@end
