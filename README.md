ETA iOS SDK
===========

Introduction
------------

This repository consists of a project, in which the SDK is used for demonstration purposes.  
To get started using the ETA SDK, simply copy ETA.h and ETA.m to your project. Both of these files can be found in the project folder.  
The ETA SDK can be used to easily call the REST API call documented on https://etilbudsavis.dk/developers/docs/.  
In addition the SDK provides a way for you to initialize a UIWebView and load a catalog within it.

Example Snippets
----------------

### Initialization
```objectivec
// Using the convenient factory method.
ETA *eta = [ETA etaWithAPIKey:@"fewf32f34f34fq34f34f4345" apiSecret:@"3h45gkw34h5gl345uibn"];

// As both the API key and secret are public properties, we can alloc init as well.
// All calls to the ETA object before the API key and secret have been set, will be ignored.
ETA *etaOldSchool = [ETA alloc] init];
etaOldSchool.apiKey = @"fewf32f34f34fq34f34f4345";
etaOldSchool.apiSecret = @"3h45gkw34h5gl345uibn";
```

###Set Location (without geocoding)
```objectivec
// The code below assumes that a location property exists on self and that it holds a CLLocation object.
// It also assumes that an eta property exists, holding an ETA object.
float accuracy = self.location.horizontalAccuracy;
float latitude = self.location.coordinate.latitude;
float longitude = self.location.coordinate.longitude;
int locationDetermined = [[NSDate date] timeIntervalSince1970];
int distance = 1000; // we want results from within 1km
[self.eta setLocationWithAccuracy:accuracy latitude:latitude longitude:longitude locationDetermined:locationDetermined distance:distance];
```

###Set Location (with geocoding)
```objectivec
// The code below assumes that a location property exists on self and that it holds a CLLocation object.
// It also assumes that an eta property exists, holding an ETA object.
// NB: The address parameter is not used a this point, so you'll have to add it
//     as an additional parameter if you wish to include it in your calls.
NSString *address = @"Hans Broges Gade 37, Aarhus C, Denmark";
float accuracy = self.location.horizontalAccuracy;
float latitude = self.location.coordinate.latitude;
float longitude = self.location.coordinate.longitude;
int locationDetermined = [[NSDate date] timeIntervalSince1970];
int distance = 1000; // we want results from within 1km
[self.eta setGeocodedLocationWithAddress:address latitude:latitude longitude:longitude locationDetermined:locationDetermined distance:distance];
```

###REST API Call
```objectivec
NSString *path = @"/api/v1/offer/list/";
ETARequestType type = ETARequestTypeGet;
NSDictionary * options = @{ @"type" : @"suggested", @"api_page" : @1, @"api_limit" : @25 };
[self.eta performAPIRequestWithPathString:path requestType:type optionsDictionary:options];
```