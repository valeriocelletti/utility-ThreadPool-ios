//
//  LSURLDispatcher.m
//  Lightstreamer client for iOS
//
//  Created by Gianluca Bertani on 03/09/12.
//  Copyright (c) 2012 Weswit srl. All rights reserved.
//

#import "LSURLDispatcher.h"
#import "LSURLDispatchOperation.h"
#import "LSURLDispatcherThread.h"
#import "LSConnectionInfo.h"
#import "LSThreadPool.h"
#import "LSInvocation.h"
#import "LSTimerThread.h"
#import "LSLog.h"

#define MIN_SPARE_URL_CONNECTIONS                           (1)

#define MAX_THREAD_IDLENESS                                (10.0)
#define THREAD_COLLECTOR_DELAY                             (15.0)


@interface LSURLDispatcher ()


#pragma mark -
#pragma mark Thread management

- (void) collectIdleThreads;
- (void) stopThreads;


#pragma mark -
#pragma mark Internal methods

- (BOOL) isLongRequestAllowedToEndPoint:(NSString *)endPoint;

- (NSString *) endPointForURL:(NSURL *)url;
- (NSString *) endPointForRequest:(NSURLRequest *)request;
- (NSString *) endPointForHost:(NSString *)host port:(int)port;


@end


static LSURLDispatcher *__sharedDispatcher= nil;

@implementation LSURLDispatcher


#pragma mark -
#pragma mark Singleton management

+ (LSURLDispatcher *) sharedDispatcher {
	if (__sharedDispatcher)
		return __sharedDispatcher;
	
	@synchronized ([LSURLDispatcher class]) {
		if (!__sharedDispatcher)
			__sharedDispatcher= [[LSURLDispatcher alloc] init];
	}
	
	return __sharedDispatcher;
}

+ (void) dispose {
	if (!__sharedDispatcher)
		return;
	
	@synchronized ([LSURLDispatcher class]) {
		if (__sharedDispatcher) {
			[__sharedDispatcher stopThreads];
			
			[__sharedDispatcher release];
			__sharedDispatcher= nil;
		}
	}
}


#pragma mark -
#pragma mark Initialization

- (id) init {
	if ((self = [super init])) {
		
		// Initialization
		_freeThreadsByEndPoint= [[NSMutableDictionary alloc] init];
		_busyThreadsByEndPoint= [[NSMutableDictionary alloc] init];

		_longRequestCountsByEndPoint= [[NSMutableDictionary alloc] init];
        
		_waitForFreeThread= [[NSCondition alloc] init];
        _nextThreadId= 1;
	}
	
	return self;
}

- (void) dealloc {
	[LSURLDispatcher dispose];
	
	[_freeThreadsByEndPoint release];
	[_busyThreadsByEndPoint release];

	[_longRequestCountsByEndPoint release];
	
	[_waitForFreeThread release];
	
	[super dealloc];
}


#pragma mark -
#pragma mark URL request dispatching and checking

- (NSData *) dispatchSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
	NSString *endPoint= [self endPointForRequest:request];
	LSURLDispatchOperation *dispatchOp= [[LSURLDispatchOperation alloc] initWithURLRequest:request endPoint:endPoint delegate:nil gatherData:YES isLong:NO];

	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"starting synchronous operation %p for end-point %@", dispatchOp, endPoint];

	// Start the operation
	[dispatchOp start];
	[dispatchOp waitForCompletion];

	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"synchronous operation %p for end-point %@ finished", dispatchOp, endPoint];

	if (response)
		*response= dispatchOp.response;
	
	if (error)
		*error= dispatchOp.error;
	
	[dispatchOp autorelease];
	
	return dispatchOp.data;
}

- (LSURLDispatchOperation *) dispatchLongRequest:(NSURLRequest *)request delegate:(id <LSURLDispatchDelegate>)delegate {
	NSString *endPoint= [self endPointForRequest:request];

	// Check if there's room for another long running request
	int count= 0;
	@synchronized (_longRequestCountsByEndPoint) {
		count= [[_longRequestCountsByEndPoint objectForKey:endPoint] intValue];

		int maxLongOperations= [LSConnectionInfo maxConcurrentSessionsPerServer] - MIN_SPARE_URL_CONNECTIONS;
		if (count >= maxLongOperations)
			@throw [NSException exceptionWithName:NSInvalidArgumentException
										   reason:@"Maximum number of concurrent long requests reached for end-point"
										 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
												   endPoint, @"endPoint",
												   [NSNumber numberWithInt:count], @"count",
												   nil]];

		// Update long running request count
		count++;

		[_longRequestCountsByEndPoint setObject:[NSNumber numberWithInt:count] forKey:endPoint];
	}
	
	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"long running request count: %d", count];

	LSURLDispatchOperation *dispatchOp= [[LSURLDispatchOperation alloc] initWithURLRequest:request endPoint:endPoint delegate:delegate gatherData:NO isLong:YES];

	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"starting long operation %p for end-point %@", dispatchOp, endPoint];
	
	return [dispatchOp autorelease];
}

- (LSURLDispatchOperation *) dispatchShortRequest:(NSURLRequest *)request delegate:(id <LSURLDispatchDelegate>)delegate {
	NSString *endPoint= [self endPointForRequest:request];
	
	LSURLDispatchOperation *dispatchOp= [[LSURLDispatchOperation alloc] initWithURLRequest:request endPoint:endPoint delegate:delegate gatherData:NO isLong:NO];

	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"starting short operation %p for end-point %@", dispatchOp, endPoint];
	
	return [dispatchOp autorelease];
}

- (BOOL) isLongRequestAllowed:(NSURLRequest *)request {
	NSString *endPoint= [self endPointForRequest:request];
    
    return [self isLongRequestAllowedToEndPoint:endPoint];
}

- (BOOL) isLongRequestAllowedToURL:(NSURL *)url {
	NSString *endPoint= [self endPointForURL:url];
    
    return [self isLongRequestAllowedToEndPoint:endPoint];
}

- (BOOL) isLongRequestAllowedToHost:(NSString *)host port:(int)port {
	NSString *endPoint= [self endPointForHost:host port:port];

    return [self isLongRequestAllowedToEndPoint:endPoint];
}


#pragma mark -
#pragma mark Thread pool management (for use by operations)

- (LSURLDispatcherThread *) preemptThreadForEndPoint:(NSString *)endPoint {
	LSURLDispatcherThread *thread= nil;
	
    int poolSize= 0;
    int activeSize= 0;
	do {
		@synchronized (_freeThreadsByEndPoint) {
			
			// Retrieve data structures
			NSMutableArray *freeThreads= [_freeThreadsByEndPoint objectForKey:endPoint];
			if (!freeThreads) {
				freeThreads= [[[NSMutableArray alloc] init] autorelease];

				[_freeThreadsByEndPoint setObject:freeThreads forKey:endPoint];
			}
			
			NSMutableArray *busyThreads= [_busyThreadsByEndPoint objectForKey:endPoint];
			if (!busyThreads) {
				busyThreads= [[[NSMutableArray alloc] init] autorelease];
				
				[_busyThreadsByEndPoint setObject:busyThreads forKey:endPoint];
			}
			
			// Get first free worker thread
			if ([freeThreads count] > 0) {
				thread= (LSURLDispatcherThread *) [[freeThreads objectAtIndex:0] retain];

				[freeThreads removeObjectAtIndex:0];
			}
			
			if (!thread) {
				
				// Check if we have to wait or create a new one
				if ([busyThreads count] < [LSConnectionInfo maxConcurrentSessionsPerServer]) {
					thread= [[LSURLDispatcherThread alloc] init];
					thread.name= [NSString stringWithFormat:@"LS URL Dispatcher Thread %d", _nextThreadId];
					
					[thread start];
					
					_nextThreadId++;
				}
			}

			if (thread) {
				[busyThreads addObject:[thread autorelease]];
			
				activeSize= [busyThreads count];
				poolSize= activeSize + [freeThreads count];
				break;
			}
		}
		
		if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
			[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"waiting for a free thread", thread, endPoint, poolSize, activeSize];

		// If we've got here, we have to wait for a free thread and retry
		[_waitForFreeThread lock];
		[_waitForFreeThread wait];
		[_waitForFreeThread unlock];

	} while (YES);
	
    if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"preempted thread %p for end-point %@, pool size is now %d (%d active)", thread, endPoint, poolSize, activeSize];

	return thread;
}

- (void) releaseThread:(LSURLDispatcherThread *)thread forEndPoint:(NSString *)endPoint {
    int poolSize= 0;
    int activeSize= 0;
	@synchronized (_freeThreadsByEndPoint) {

		// Retrieve data structures
		NSMutableArray *freeThreads= [_freeThreadsByEndPoint objectForKey:endPoint];
		if (!freeThreads) {
			freeThreads= [[[NSMutableArray alloc] init] autorelease];
			
			[_freeThreadsByEndPoint setObject:freeThreads forKey:endPoint];
		}
		
		NSMutableArray *busyThreads= [_busyThreadsByEndPoint objectForKey:endPoint];
		if (!busyThreads) {
			busyThreads= [[[NSMutableArray alloc] init] autorelease];
			
			[_busyThreadsByEndPoint setObject:busyThreads forKey:endPoint];
		}

		// Release the thread
		[freeThreads addObject:thread];
		[busyThreads removeObject:thread];
        
        thread.lastActivity= [[NSDate date] timeIntervalSinceReferenceDate];
        
        activeSize= [busyThreads count];
        poolSize= activeSize + [freeThreads count];
	}
	
	// Signal there's a free thread
	[_waitForFreeThread lock];
	[_waitForFreeThread signal];
	[_waitForFreeThread unlock];
    
	// Reschedule idle thread collector
    [[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(collectIdleThreads)];
    [[LSTimerThread sharedTimer] performSelector:@selector(collectIdleThreads) onTarget:self afterDelay:THREAD_COLLECTOR_DELAY];
    
    if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"released thread %p for end-point %@, pool size is now %d (%d active)", thread, endPoint, poolSize, activeSize];
}

- (void) operationDidFinish:(LSURLDispatchOperation *)dispatchOp {
	if (dispatchOp.isLong) {
		
		// Update long running request count
		int count= 0;
		@synchronized (_longRequestCountsByEndPoint) {
			count= [[_longRequestCountsByEndPoint objectForKey:dispatchOp.endPoint] intValue];
			count--;
			
			[_longRequestCountsByEndPoint setObject:[NSNumber numberWithInt:count] forKey:dispatchOp.endPoint];
		}
		
		if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
			[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"long running request count: %d", count];
	}
	
	if (dispatchOp.thread) {
		
		// Release connection thread to thread pool
		[self releaseThread:dispatchOp.thread forEndPoint:dispatchOp.endPoint];
	}
}


#pragma mark -
#pragma mark Thread management

- (void) collectIdleThreads {
	@synchronized (_freeThreadsByEndPoint) {
        NSTimeInterval now= [[NSDate date] timeIntervalSinceReferenceDate];
        
        for (NSString *endPoint in [_freeThreadsByEndPoint allKeys]) {
            NSMutableArray *freeThreads= [_freeThreadsByEndPoint objectForKey:endPoint];

            NSMutableArray *toBeCollected= [[NSMutableArray alloc] init];
            for (LSURLDispatcherThread *thread in freeThreads) {
                if ((now - thread.lastActivity) > MAX_THREAD_IDLENESS) {
                    [thread stopThread];
                    
                    [toBeCollected addObject:thread];
                }
            }
        
            [freeThreads removeObjectsInArray:toBeCollected];
            [toBeCollected release];
        }
    }

	if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"collected threads for all end-points"];
}

- (void) stopThreads {
	@synchronized (_freeThreadsByEndPoint) {
        for (NSMutableArray *freeThreads in [_freeThreadsByEndPoint allValues]) {
            for (LSURLDispatcherThread *thread in freeThreads)
                [thread stopThread];
        
            [freeThreads removeAllObjects];
        }
        
        for (NSMutableArray *busyThreads in [_busyThreadsByEndPoint allValues]) {
            for (LSURLDispatcherThread *thread in busyThreads)
                [thread stopThread];
        
            [busyThreads removeAllObjects];
        }
	}
    
    if ([LSLog isSourceTypeEnabled:LOG_SRC_URL_DISPATCHER])
		[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:self log:@"stopped all threads, pools are now all empty"];
}


#pragma mark -
#pragma mark Internal methods

- (BOOL) isLongRequestAllowedToEndPoint:(NSString *)endPoint {
	int count= 0;
    
	@synchronized (_longRequestCountsByEndPoint) {
		count= [[_longRequestCountsByEndPoint objectForKey:endPoint] intValue];
	}
	
	// Let's leave 2 spare connections for short requests
	int maxLongOperations= [LSConnectionInfo maxConcurrentSessionsPerServer] - MIN_SPARE_URL_CONNECTIONS;
	return (count < maxLongOperations);
}

- (NSString *) endPointForURL:(NSURL *)url {
	int port= [url.port intValue];
	if (!port)
		port= ([url.scheme isEqualToString:@"https"] ? 443 : 80);
    
    return [self endPointForHost:url.host port:port];
}

- (NSString *) endPointForRequest:(NSURLRequest *)request {
    return [self endPointForURL:request.URL];
}

- (NSString *) endPointForHost:(NSString *)host port:(int)port {
	NSString *endPoint= [NSString stringWithFormat:@"%@:%d", host, port];
	
	return endPoint;
}


@end
