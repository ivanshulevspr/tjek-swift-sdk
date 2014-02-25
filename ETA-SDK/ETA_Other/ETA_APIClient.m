//
//  ETA_APIClient.m
//  ETA-SDK
//
//  Created by Laurie Hufford on 7/8/13.
//  Copyright (c) 2013 eTilbudsavis. All rights reserved.
//

#import "ETA_APIClient.h"

#import "ETA.h"
#import "ETA_Session.h"
#import "ETA_API.h"

#import "NSValueTransformer+ETAPredefinedValueTransformers.h"


#import <CommonCrypto/CommonDigest.h>

static NSString* const kETA_SessionUserDefaultsKey = @"ETA_Session";


@interface ETA_APIClient ()

@property (nonatomic, readwrite, strong) NSString *apiKey;
@property (nonatomic, readwrite, strong) NSString *apiSecret;
@property (nonatomic, readwrite, strong) NSString *appVersion;

@end


@implementation ETA_APIClient
{
    dispatch_semaphore_t _startingSessionLock;
    dispatch_queue_t _syncQueue;
}


#pragma mark - Constructors

+ (instancetype)clientWithApiKey:(NSString*)apiKey apiSecret:(NSString*)apiSecret appVersion:(NSString*)appVersion
{
    return [self clientWithBaseURL:[NSURL URLWithString:kETA_APIBaseURLString]
                            apiKey:apiKey
                         apiSecret:apiSecret
                        appVersion:appVersion];
}

+ (instancetype)clientWithBaseURL:(NSURL *)url apiKey:(NSString*)apiKey apiSecret:(NSString*)apiSecret appVersion:(NSString*)appVersion
{
    ETA_APIClient* client = [[ETA_APIClient alloc] initWithBaseURL:url];
    client.apiKey = apiKey;
    client.apiSecret = apiSecret;
    client.appVersion = appVersion;
    return client;
}

- (id)initWithBaseURL:(NSURL *)url
{
    if ((self = [super initWithBaseURL:url]))
    {
        _syncQueue = dispatch_queue_create("com.eTilbudsavis.ETA_APIClient.syncQ", 0);
        
        _startingSessionLock = dispatch_semaphore_create(1);
        
        self.responseSerializer = [AFJSONResponseSerializer serializer];
        self.requestSerializer = [AFJSONRequestSerializer serializer];
        
        self.storageEnabled = YES;
        self.verbose = NO;
    }
    return self;
}


- (void) log:(NSString*)format, ...
{
    if (!self.verbose)
        return;
    
    va_list args;
    va_start(args, format);
    NSString* msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[ETA_APIClient] %@", msg);
}


#pragma mark - API Requests

// the parameters that are derived from the client, that may be overridded by the request
- (NSDictionary*) baseRequestParameters
{
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    if (self.appVersion)
        params[@"api_av"] = self.appVersion;
    return params;
}
// send a request, and on sucessful response update the session token, if newer
- (void) makeRequest:(NSString*)requestPath type:(ETARequestType)type parameters:(NSDictionary*)parameters completion:(void (^)(id JSONResponse, NSError* error))completionHandler
{
    [self makeRequest:requestPath type:type parameters:parameters remainingRetries:1 completion:completionHandler];
}
// send a request, and on sucessful response update the session token, if newer
- (void) makeRequest:(NSString*)requestPath type:(ETARequestType)type parameters:(NSDictionary*)parameters remainingRetries:(NSUInteger)remainingRetries completion:(void (^)(id JSONResponse, NSError* error))completionHandler
{
    // push the makeRequest to the sync queue, which will be blocked while creating sessions
    // as it is quickly sent on to AFNetworking's operation queue, it wont block the sync queue for long
    dispatch_async(_syncQueue, ^{
        
        // the code that does the actual sending of the request
        void (^sendBlock)() = ^{
            // get the base parameters, and override them with those passed in
            NSMutableDictionary* mergedParameters = [[self baseRequestParameters] mutableCopy];
            [mergedParameters setValuesForKeysWithDictionary:parameters];
            
            // convert any arrays into a comma separated list
            NSMutableDictionary* cleanedParameters = [NSMutableDictionary dictionary];
            [mergedParameters enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                if ([obj isKindOfClass:[NSArray class]])
                {
                    obj = [obj componentsJoinedByString:@","];
                }
                [cleanedParameters setValue:obj forKey:key];
            }];
                        
            void (^successBlock)(AFHTTPRequestOperation*, id) = ^(AFHTTPRequestOperation *operation, id responseObject)
            {
                
                [self updateSessionTokenFromHeaders:operation.response.allHeaderFields];
                if (completionHandler)
                    completionHandler(responseObject, nil);
            };
            void (^failureBlock)(AFHTTPRequestOperation*, id) = ^(AFHTTPRequestOperation *operation, NSError *error)
            {
                NSError* etaError = [[self class] etaErrorFromAFNetworkingError:error];
                
                NSInteger code = etaError.code;
                if (remainingRetries > 0)
                {
                    // Errors that require a new session
                    // 1101 & 1108: token expired / invalid token
                    if (code == 1101 || code == 1108)
                    {
                        [self log:@"Error %d while making request '%@' - Reset Session and retry '%@'", code, requestPath, etaError.localizedDescription];
                        // create a new session, and if it was successful, repeat the request we were making
                        [self startSessionOnSyncQueue:YES forceReset:YES withCompletion:^(NSError *error) {
                            if (!error)
                            {
                                [self makeRequest:requestPath type:type parameters:parameters remainingRetries:remainingRetries-1 completion:^(id response, NSError *error) {
                                    if (error)
                                        NSLog(@"Retry Error!");
                                    completionHandler(response, error);
                                }];
                            }
                            else
                            {
                                if (!error)
                                    error = etaError;
                                
                                completionHandler(nil, error);
                            }
                        }];
                        return;
                    }
                    // errors that require a retry
                    // 2015: non-critical error
                    else if (code == 2015)
                    {
                        // find how long until we retry - if not set then will retry instantly
                        NSInteger retryAfter = [operation.response.allHeaderFields[@"Retry-After"] integerValue];
                        
                        [self log:@"Non-critical error while making request - Retrying after %d secs", code, retryAfter];
                        
                        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryAfter * NSEC_PER_SEC));
                        dispatch_after(popTime, _syncQueue, ^(void){
                            [self makeRequest:requestPath type:type parameters:parameters remainingRetries:remainingRetries-1 completion:completionHandler];
                        });
                        return;
                    }
                }
                
                // an unsolveable error, or ran our of retries - eject!
                if (completionHandler)
                {
                    completionHandler(nil, etaError ?: error);
                }
            };
            
            switch (type)
            {
                case ETARequestTypeGET:
                    [self GET:requestPath parameters:cleanedParameters success:successBlock failure:failureBlock];
                    break;
                case ETARequestTypePOST:
                    [self POST:requestPath parameters:cleanedParameters success:successBlock failure:failureBlock];
                    break;
                case ETARequestTypePUT:
                    [self PUT:requestPath parameters:cleanedParameters success:successBlock failure:failureBlock];
                    break;
                case ETARequestTypeDELETE:
                    [self DELETE:requestPath parameters:cleanedParameters success:successBlock failure:failureBlock];
                    break;
                default:
                    break;
            }
        };
        
        // the session hasnt been created, or it failed when previously created
        // try to create the session from scratch.
        // we are currently on the syncQ, so dont syncronously dispatch the start to the syncQ
        if (!self.session)
        {
            [self startSessionOnSyncQueue:NO forceReset:NO withCompletion:^(NSError *error) {
                // if we were able to create the session, do the send request
                if (!error)
                    sendBlock();
                // if the creation failed, send the error up to the request
                else if (completionHandler)
                    completionHandler(nil, error);
            }];
            
            dispatch_semaphore_signal(_startingSessionLock);
        }
        // we have a session, so just run the sendBlock
        else
        {
            sendBlock();
        }
    });
}



#pragma mark - Headers

// When the secret changes, the headers must update
- (void) setApiSecret:(NSString *)apiSecret
{
    _apiSecret = apiSecret;
    
    [self updateHeaders];
}

// Update the client's headers to use the session's token
- (void) updateHeaders
{
    NSString* hash = nil;
    if (self.session.token && self.apiSecret)
    {
        // try to make an SHA256 Hex string
        NSData* hashData = [[NSString stringWithFormat:@"%@%@", self.apiSecret, self.session.token] dataUsingEncoding:NSUTF8StringEncoding];
        
        unsigned char result[CC_SHA256_DIGEST_LENGTH];
        if (CC_SHA256(hashData.bytes, hashData.length, result)) {
            NSMutableString *res = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
            for (int i = 0; i<CC_SHA256_DIGEST_LENGTH; i++) {
                [res appendFormat:@"%02x",result[i]];
            }
            hash = [NSString stringWithString: res];
        }
    }
    
    
    NSDictionary* httpheaders = self.requestSerializer.HTTPRequestHeaders;
    
    [self log: @"Updating Headers - Token:'%@'->'%@' Sig:'%@'->'%@'", httpheaders[@"X-Token"], self.session.token, httpheaders[@"X-Signature"], hash];
    
    [self.requestSerializer setValue:self.session.token forHTTPHeaderField:@"X-Token"];
    [self.requestSerializer setValue:hash               forHTTPHeaderField:@"X-Signature"];
}




#pragma mark - Session Setters

- (void) setIfSameOrNewerSession:(ETA_Session *)session
{
    if ([session isExpiryTheSameAsSession:self.session] ||
        [session isExpiryNewerThanSession:self.session])
    {
        self.session = session;
    }
}
- (void) setIfNewerSession:(ETA_Session *)session
{
    if ([session isExpiryNewerThanSession:self.session])
    {
        self.session = session;
    }
}


// Setting the session causes the change to be persisted to User Defaults
- (void) setSession:(ETA_Session *)session
{
    [self log: @"Setting Session '%@' (%@) => '%@' (%@)", _session.token, _session.expires, session.token, session.expires];
    
    _session = session;
    [self updateHeaders];
    [self saveSessionToStorage];
}

// This will only update the session token/expiry if the expiry is newer
- (void) updateSessionTokenFromHeaders:(NSDictionary*)headers
{
    NSString* newToken = headers[@"X-Token"];
    
    NSDate* newExpiryDate = [ETA_API.dateFormatter dateFromString:headers[@"X-Token-Expires"]];
    
    if (!newExpiryDate || !newToken)
        return;
    
    // check if it would change anything about the session.
    // if the tokens are the same and the new date is not newer then it's a no-op
    if ([self.session.token isEqualToString:newToken])
        return;
    if (self.session.expires && [newExpiryDate compare: self.session.expires]!=NSOrderedDescending)
        return;
        
    // merge the expiry/token with the current session
    ETA_Session* newSession = [self.session copy];
    [newSession setValuesForKeysWithDictionary:@{@"token":newToken,
                                                 @"expires":newExpiryDate}];
    
    [self log: @"Updating Session Tokens - '%@' (%@) => '%@' (%@)", self.session.token, self.session.expires, newSession.token, newSession.expires];
    self.session = newSession;
}

#pragma mark - Session Loading / Updating / Saving

// get the session, either from local storage or creating a new one, and make sure it's up to date
// it will perform it on the sync queue
- (void) startSessionWithCompletion:(void (^)(NSError* error))completionHandler
{
    [self startSessionOnSyncQueue:YES forceReset:NO withCompletion:completionHandler];
}

- (void) startSessionOnSyncQueue:(BOOL)dispatchOnSyncQ forceReset:(BOOL)forceReset withCompletion:(void (^)(NSError* error))completionHandler
{
    // do it on the sync queue, and block until the completion occurs - that way any other requests will have to wait for the session to have started
    void (^block)() = ^{
        // we are asking to reset the session - just delete existing session
        if (forceReset)
        {
            self.session = nil;
        }
        // a previous connect was sucessful - dont bother connecting (and dont block syncQ with completion handler
        else if (self.session)
        {
            if (completionHandler)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil);
                });
            }
            return;
        }
        
        // create a semaphore, so that the queue's block doesn't end until the completion handler is hit
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        
        
        // fill self.session with the session from user defaults, or nil if not set
        [self loadSessionFromStorage];
        
        // if there is no session, or either renew or update fail, call this block, which tries to create a new session
        void (^createSessionBlock)() = ^{
            [self log: @"Resetting session before creating - '%@' => '%@'", self.session.token, nil];
            self.session = nil;
            [self createSessionWithCompletion:^(NSError *error) {
                if (error)
                {
                    [self log: @"Unable to create session - %@", error];
                }
                dispatch_semaphore_signal(sema); // tell the syncQueue block to finish
                if (completionHandler)
                    completionHandler(error);
            }];
        };
        
        // session loaded from local store - check its state
        if (self.session)
        {
//            // if the session is out of date, renew it
//            if ([self.session willExpireSoon])
//            {
                [self renewSessionWithCompletion:^(NSError *error) {
                    if (error && error.code != NSURLErrorNotConnectedToInternet)
                    {
                        [self log: @"Unable to renew session - trying to create a new one instead: %@", error];
                        createSessionBlock();
                    }
                    else
                    {
                        dispatch_semaphore_signal(sema); // tell the syncQueue block to finish
                        if (completionHandler)
                            completionHandler(error);
                    }
                }];
//            }
//            // if not out of date, update it
//            else
//            {
//                [self updateSessionWithCompletion:^(NSError *error) {
//                    if (error && error.code != NSURLErrorNotConnectedToInternet)
//                    {
//                        [self log: @"Unable to update session - trying to create a new one instead: %@", error.localizedDescription];
//                        createSessionBlock();
//                    }
//                    else
//                    {
//                        dispatch_semaphore_signal(sema); // tell the syncQueue block to finish
//                        if (completionHandler)
//                            completionHandler(error);
//                    }
//                }];
//            }
        }
        // no previous session exists - create a new one
        else
        {
            createSessionBlock(nil);
        }
        
        // wait for the semaphore that is going to be called when the getting of the session completes
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    };
    
    if (dispatchOnSyncQ)
        dispatch_async(_syncQueue, block);
    else
        block();
}

// get the session from UserDefaults
- (void) loadSessionFromStorage
{
    if (!self.storageEnabled)
        return;
    
    NSString* sessionJSON = [[NSUserDefaults standardUserDefaults] valueForKey:kETA_SessionUserDefaultsKey];
    NSDictionary* sessionDict = (sessionJSON) ? [NSJSONSerialization JSONObjectWithData:[sessionJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    ETA_Session* session = nil;
    if (sessionDict)
    {
        session = [ETA_Session objectFromJSONDictionary:sessionDict];
    }
    [self log: @"Loading Session - '%@' => '%@'", self.session.token, session.token];
    self.session = session;
}

// save the session to local storage
- (void) saveSessionToStorage
{
    if (!self.storageEnabled)
        return;
    
    NSString* sessionJSON = nil;
    if (self.session)
    {
        NSDictionary* sessionDict = [self.session JSONDictionary];
        
        sessionJSON = [[NSString alloc] initWithData: [NSJSONSerialization dataWithJSONObject:sessionDict options:0 error:nil]
                                            encoding: NSUTF8StringEncoding];
    }
    [[NSUserDefaults standardUserDefaults] setObject: sessionJSON
                                              forKey:kETA_SessionUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
    
// create a new session, and assign
- (void) createSessionWithCompletion:(void (^)(NSError* error))completionHandler
{
    NSInteger tokenLife = 90*24*60*60;
//    NSInteger tokenLife = 5;
    
    NSHTTPCookieStorage *cookieJar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    
    NSHTTPCookie* hashCookie = nil; // nomnomnom
    NSHTTPCookie* idCookie = nil;
    NSHTTPCookie* timeCookie = nil;
    
    for (NSHTTPCookie *cookie in [cookieJar cookies]) {
        NSString* name = cookie.name;
        if ([name caseInsensitiveCompare:@"auth[hash]"] == NSOrderedSame)
            hashCookie = cookie;
        else if ([name caseInsensitiveCompare:@"auth[id]"] == NSOrderedSame)
            idCookie = cookie;
        else if ([name caseInsensitiveCompare:@"auth[time]"] == NSOrderedSame)
            timeCookie = cookie;
    }

    NSMutableDictionary* params = [[self baseRequestParameters] mutableCopy];
    
    [params setValuesForKeysWithDictionary:@{ @"api_key": (self.apiKey) ?: [NSNull null],
                                              @"token_ttl": @(tokenLife) }];
    
    if (hashCookie && idCookie && timeCookie)
    {
        params[@"v1_auth_hash"] = hashCookie.value;
        params[@"v1_auth_id"] = idCookie.value;
        params[@"v1_auth_time"] = timeCookie.value;
    }

    [self POST:[ETA_API path:ETA_API.sessions]
        parameters:params
           success:^(AFHTTPRequestOperation *operation, id responseObject) {
               
               if (hashCookie && idCookie && timeCookie)
               {
                   [cookieJar deleteCookie:hashCookie];
                   [cookieJar deleteCookie:idCookie];
                   [cookieJar deleteCookie:timeCookie];
               }
               
               NSError* error = nil;
               ETA_Session* session = [ETA_Session objectFromJSONDictionary:responseObject];
               
               // save the session that was created, only if we have created it after any previous requests
               if (session)
               {
                   [self log: @"Creating Session - '%@' => '%@'", self.session.token, session.token];
                   
                   [self setIfSameOrNewerSession:session];
               }
               //TODO: create error if nil session
               
               
               if (completionHandler)
                   completionHandler(error);
           }
           failure:^(AFHTTPRequestOperation *operation, NSError *error) {
               if (hashCookie && idCookie && timeCookie)
               {
                   [cookieJar deleteCookie:hashCookie];
                   [cookieJar deleteCookie:idCookie];
                   [cookieJar deleteCookie:timeCookie];
               }
               
               NSError* etaError = [[self class] etaErrorFromAFNetworkingError:error];
               
               if (completionHandler)
                   completionHandler((etaError) ?: error);
           }];
}

// get the latest state of the session
- (void) updateSessionWithCompletion:(void (^)(NSError* error))completionHandler
{
    [self GET:[ETA_API path:ETA_API.sessions]
       parameters:[self baseRequestParameters]
          success:^(AFHTTPRequestOperation *operation, id responseObject) {
              NSError* error = nil;
              ETA_Session* session = [ETA_Session objectFromJSONDictionary:responseObject];

              // save the session that was update, only if we have updated it after any previous requests
              if (session)
              {
                  [self log: @"Updating Session - '%@' => '%@'", self.session.token, session.token];
                  [self setIfSameOrNewerSession:session];
              }
              //TODO: create error if nil session
              
              if (completionHandler)
                  completionHandler(error);
           }
           failure:^(AFHTTPRequestOperation *operation, NSError *error) {
               NSError* etaError = [[self class] etaErrorFromAFNetworkingError:error];
               
               if (completionHandler)
                   completionHandler((etaError) ?: error);
           }];
}

// Ask for a new expiration date / token
- (void) renewSessionWithCompletion:(void (^)(NSError* error))completionHandler
{
    [self PUT:[ETA_API path:ETA_API.sessions]
       parameters:[self baseRequestParameters]
          success:^(AFHTTPRequestOperation *operation, id responseObject) {
              NSError* error = nil;
              ETA_Session* session = [ETA_Session objectFromJSONDictionary:responseObject];

              // save the session that was renewed, only if we have renewed it after any previous requests
              if (session)
              {
                  [self log: @"Renewing Session - '%@' => '%@'", self.session.token, session.token];
                  [self setIfSameOrNewerSession:session];
              }
              //TODO: create error if nil session
              
              if (completionHandler)
                  completionHandler(error);
          }
          failure:^(AFHTTPRequestOperation *operation, NSError *error) {
              NSError* etaError = [[self class] etaErrorFromAFNetworkingError:error];
              
              if (completionHandler)
                  completionHandler((etaError) ?: error);
          }];
}



#pragma mark - Session User Management

- (void) attachUser:(NSDictionary*)userCredentials withCompletion:(void (^)(NSError* error))completionHandler
{
    [self makeRequest:[ETA_API path:ETA_API.sessions]
                 type:ETARequestTypePUT
           parameters:userCredentials
           completion:^(id response, NSError *error) {
               
               error = ([[self class] etaErrorFromAFNetworkingError:error]) ?: error;
               
               ETA_Session* session = [ETA_Session objectFromJSONDictionary:response];
               
               // save the session, only if after any previous requests
               if (session)
               {
                   [self log: @"Attaching User to Session - '%@' => '%@'", self.session.token, session.token];
                   [self setIfSameOrNewerSession:session];
               }
               //TODO: create error if nil session
               
               if (completionHandler)
                   completionHandler(error);
           }];
}
- (void) detachUserWithCompletion:(void (^)(NSError* error))completionHandler
{
    [self makeRequest:[ETA_API path:ETA_API.sessions]
                 type:ETARequestTypePUT
           parameters:@{ @"email":@"" }
           completion:^(id response, NSError *error) {
               
               error = ([[self class] etaErrorFromAFNetworkingError:error]) ?: error;
               
               ETA_Session* session = [ETA_Session objectFromJSONDictionary:response];
               
               // save the session, only if after any previous requests
               if (session)
               {
                   [self log: @"Detaching User from Session - '%@' => '%@'", self.session.token, session.token];
                   [self setIfSameOrNewerSession:session];
               }
               //TODO: create error if nil session
               
               if (completionHandler)
                   completionHandler(error);
           }];
}


- (BOOL) allowsPermission:(NSString*)actionPermission
{
    return [self.session allowsPermission:actionPermission];
}



+ (NSError*) etaErrorFromAFNetworkingError:(NSError*)AFNetworkingError
{
    NSDictionary* etaErrorDict = nil;
    NSString* errorDesc = AFNetworkingError.userInfo[NSLocalizedRecoverySuggestionErrorKey];
    if (errorDesc)
        etaErrorDict = [NSJSONSerialization JSONObjectWithData:[errorDesc dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    
    if (![etaErrorDict isKindOfClass:NSDictionary.class])
        return nil;
    
    NSString* errCode = etaErrorDict[@"code"];
    if (!errCode)
        return nil;
    
    NSMutableDictionary* userInfo = [NSMutableDictionary dictionary];
    
    [userInfo setValue:etaErrorDict[@"message"] forKey:NSLocalizedDescriptionKey];
    [userInfo setValue:etaErrorDict[@"details"] forKey:NSLocalizedFailureReasonErrorKey];
    [userInfo setValue:etaErrorDict[@"@note.1"] forKey:NSLocalizedRecoverySuggestionErrorKey];
    [userInfo setValue:etaErrorDict[@"id"] forKey:ETA_APIError_ErrorIDKey];
    [userInfo setValue:etaErrorDict forKey:ETA_APIError_ErrorObjectKey];
    [userInfo setValue:AFNetworkingError.userInfo[AFNetworkingOperationFailingURLResponseErrorKey] forKey:ETA_APIError_URLResponseKey];
    
    return [NSError errorWithDomain:ETA_APIErrorDomain code:errCode.integerValue userInfo:userInfo];
}


@end
