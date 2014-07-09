/*
 Copyright (c) 2012-2014, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "GCDWebServerPrivate.h"

#define kMultiPartBufferSize (256 * 1024)

typedef enum {
  kParserState_Undefined = 0,
  kParserState_Start,
  kParserState_Headers,
  kParserState_Content,
  kParserState_End
} ParserState;

@interface GCDWebServerMIMEStreamParser : NSObject
- (id)initWithBoundary:(NSString*)boundary defaultControlName:(NSString*)name arguments:(NSMutableArray*)arguments files:(NSMutableArray*)files;
- (BOOL)appendBytes:(const void*)bytes length:(NSUInteger)length;
- (BOOL)isAtEnd;
@end

static NSData* _newlineData = nil;
static NSData* _newlinesData = nil;
static NSData* _dashNewlineData = nil;

@interface GCDWebServerMultiPart () {
@private
  NSString* _controlName;
  NSString* _contentType;
  NSString* _mimeType;
}
@end

@implementation GCDWebServerMultiPart

@synthesize controlName=_controlName, contentType=_contentType, mimeType=_mimeType;

- (id)initWithControlName:(NSString*)name contentType:(NSString*)type {
  if ((self = [super init])) {
    _controlName = [name copy];
    _contentType = [type copy];
    _mimeType = ARC_RETAIN(GCDWebServerTruncateHeaderValue(_contentType));
  }
  return self;
}

- (void)dealloc {
  ARC_RELEASE(_controlName);
  ARC_RELEASE(_contentType);
  ARC_RELEASE(_mimeType);
  
  ARC_DEALLOC(super);
}

@end

@interface GCDWebServerMultiPartArgument () {
@private
  NSData* _data;
  NSString* _string;
}
@end

@implementation GCDWebServerMultiPartArgument

@synthesize data=_data, string=_string;

- (id)initWithControlName:(NSString*)name contentType:(NSString*)type data:(NSData*)data {
  if ((self = [super initWithControlName:name contentType:type])) {
    _data = ARC_RETAIN(data);
    
    if ([self.contentType hasPrefix:@"text/"]) {
      NSString* charset = GCDWebServerExtractHeaderValueParameter(self.contentType, @"charset");
      _string = [[NSString alloc] initWithData:_data encoding:GCDWebServerStringEncodingFromCharset(charset)];
    }
  }
  return self;
}

- (void)dealloc {
  ARC_RELEASE(_data);
  ARC_RELEASE(_string);
  
  ARC_DEALLOC(super);
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<%@ | '%@' | %lu bytes>", [self class], self.mimeType, (unsigned long)_data.length];
}

@end

@interface GCDWebServerMultiPartFile () {
@private
  NSString* _fileName;
  NSString* _temporaryPath;
}
@end

@implementation GCDWebServerMultiPartFile

@synthesize fileName=_fileName, temporaryPath=_temporaryPath;

- (id)initWithControlName:(NSString*)name contentType:(NSString*)type fileName:(NSString*)fileName temporaryPath:(NSString*)temporaryPath {
  if ((self = [super initWithControlName:name contentType:type])) {
    _fileName = [fileName copy];
    _temporaryPath = [temporaryPath copy];
  }
  return self;
}

- (void)dealloc {
  unlink([_temporaryPath fileSystemRepresentation]);
  
  ARC_RELEASE(_fileName);
  ARC_RELEASE(_temporaryPath);
  
  ARC_DEALLOC(super);
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<%@ | '%@' | '%@>'", [self class], self.mimeType, _fileName];
}

@end

@interface GCDWebServerMIMEStreamParser () {
@private
  NSData* _boundary;
  NSString* _defaultcontrolName;
  ParserState _state;
  NSMutableData* _data;
  NSMutableArray* _arguments;
  NSMutableArray* _files;
  
  NSString* _controlName;
  NSString* _fileName;
  NSString* _contentType;
  NSString* _tmpPath;
  int _tmpFile;
  GCDWebServerMIMEStreamParser* _subParser;
}
@end

@implementation GCDWebServerMIMEStreamParser

+ (void)initialize {
  if (_newlineData == nil) {
    _newlineData = [[NSData alloc] initWithBytes:"\r\n" length:2];
    DCHECK(_newlineData);
  }
  if (_newlinesData == nil) {
    _newlinesData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
    DCHECK(_newlinesData);
  }
  if (_dashNewlineData == nil) {
    _dashNewlineData = [[NSData alloc] initWithBytes:"--\r\n" length:4];
    DCHECK(_dashNewlineData);
  }
}

- (id)initWithBoundary:(NSString*)boundary defaultControlName:(NSString*)name arguments:(NSMutableArray*)arguments files:(NSMutableArray*)files {
  NSData* data = boundary.length ? [[NSString stringWithFormat:@"--%@", boundary] dataUsingEncoding:NSASCIIStringEncoding] : nil;
  if (data == nil) {
    DNOT_REACHED();
    ARC_RELEASE(self);
    return nil;
  }
  if ((self = [super init])) {
    _boundary = ARC_RETAIN(data);
    _defaultcontrolName = ARC_RETAIN(name);
    _arguments = ARC_RETAIN(arguments);
    _files = ARC_RETAIN(files);
    _data = [[NSMutableData alloc] initWithCapacity:kMultiPartBufferSize];
    _state = kParserState_Start;
  }
  return self;
}

- (void)dealloc {
  ARC_RELEASE(_boundary);
  ARC_RELEASE(_defaultcontrolName);
  ARC_RELEASE(_data);
  ARC_RELEASE(_arguments);
  ARC_RELEASE(_files);
  
  ARC_RELEASE(_controlName);
  ARC_RELEASE(_fileName);
  ARC_RELEASE(_contentType);
  if (_tmpFile > 0) {
    close(_tmpFile);
    unlink([_tmpPath fileSystemRepresentation]);
  }
  ARC_RELEASE(_tmpPath);
  ARC_RELEASE(_subParser);
  
  ARC_DEALLOC(super);
}

// http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.2
- (BOOL)_parseData {
  BOOL success = YES;
  
  if (_state == kParserState_Headers) {
    NSRange range = [_data rangeOfData:_newlinesData options:0 range:NSMakeRange(0, _data.length)];
    if (range.location != NSNotFound) {
      
      ARC_RELEASE(_controlName);
      _controlName = nil;
      ARC_RELEASE(_fileName);
      _fileName = nil;
      ARC_RELEASE(_contentType);
      _contentType = nil;
      ARC_RELEASE(_tmpPath);
      _tmpPath = nil;
      ARC_RELEASE(_subParser);
      _subParser = nil;
      NSString* headers = [[NSString alloc] initWithData:[_data subdataWithRange:NSMakeRange(0, range.location)] encoding:NSUTF8StringEncoding];
      if (headers) {
        for (NSString* header in [headers componentsSeparatedByString:@"\r\n"]) {
          NSRange subRange = [header rangeOfString:@":"];
          if (subRange.location != NSNotFound) {
            NSString* name = [header substringToIndex:subRange.location];
            NSString* value = [[header substringFromIndex:(subRange.location + subRange.length)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
              _contentType = ARC_RETAIN(GCDWebServerNormalizeHeaderValue(value));
            } else if ([name caseInsensitiveCompare:@"Content-Disposition"] == NSOrderedSame) {
              NSString* contentDisposition = GCDWebServerNormalizeHeaderValue(value);
              if ([GCDWebServerTruncateHeaderValue(contentDisposition) isEqualToString:@"form-data"]) {
                _controlName = ARC_RETAIN(GCDWebServerExtractHeaderValueParameter(contentDisposition, @"name"));
                _fileName = ARC_RETAIN(GCDWebServerExtractHeaderValueParameter(contentDisposition, @"filename"));
              } else if ([GCDWebServerTruncateHeaderValue(contentDisposition) isEqualToString:@"file"]) {
                _controlName = ARC_RETAIN(_defaultcontrolName);
                _fileName = ARC_RETAIN(GCDWebServerExtractHeaderValueParameter(contentDisposition, @"filename"));
              }
            }
          } else {
            DNOT_REACHED();
          }
        }
        if (_contentType == nil) {
          _contentType = @"text/plain";
        }
        ARC_RELEASE(headers);
      } else {
        LOG_ERROR(@"Failed decoding headers in part of 'multipart/form-data'");
        DNOT_REACHED();
      }
      if (_controlName) {
        if ([GCDWebServerTruncateHeaderValue(_contentType) isEqualToString:@"multipart/mixed"]) {
          NSString* boundary = GCDWebServerExtractHeaderValueParameter(_contentType, @"boundary");
          _subParser = [[GCDWebServerMIMEStreamParser alloc] initWithBoundary:boundary defaultControlName:_controlName arguments:_arguments files:_files];
          if (_subParser == nil) {
            DNOT_REACHED();
            success = NO;
          }
        } else if (_fileName) {
          NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
          _tmpFile = open([path fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
          if (_tmpFile > 0) {
            _tmpPath = [path copy];
          } else {
            DNOT_REACHED();
            success = NO;
          }
        }
      } else {
        DNOT_REACHED();
        success = NO;
      }
      
      [_data replaceBytesInRange:NSMakeRange(0, range.location + range.length) withBytes:NULL length:0];
      _state = kParserState_Content;
    }
  }
  
  if ((_state == kParserState_Start) || (_state == kParserState_Content)) {
    NSRange range = [_data rangeOfData:_boundary options:0 range:NSMakeRange(0, _data.length)];
    if (range.location != NSNotFound) {
      NSRange subRange = NSMakeRange(range.location + range.length, _data.length - range.location - range.length);
      NSRange subRange1 = [_data rangeOfData:_newlineData options:NSDataSearchAnchored range:subRange];
      NSRange subRange2 = [_data rangeOfData:_dashNewlineData options:NSDataSearchAnchored range:subRange];
      if ((subRange1.location != NSNotFound) || (subRange2.location != NSNotFound)) {
        
        if (_state == kParserState_Content) {
          const void* dataBytes = _data.bytes;
          NSUInteger dataLength = range.location - 2;
          if (_subParser) {
            if (![_subParser appendBytes:dataBytes length:(dataLength + 2)] || ![_subParser isAtEnd]) {
              DNOT_REACHED();
              success = NO;
            }
            ARC_RELEASE(_subParser);
            _subParser = nil;
          } else if (_tmpPath) {
            ssize_t result = write(_tmpFile, dataBytes, dataLength);
            if (result == (ssize_t)dataLength) {
              if (close(_tmpFile) == 0) {
                _tmpFile = 0;
                GCDWebServerMultiPartFile* file = [[GCDWebServerMultiPartFile alloc] initWithControlName:_controlName contentType:_contentType fileName:_fileName temporaryPath:_tmpPath];
                [_files addObject:file];
                ARC_RELEASE(file);
              } else {
                DNOT_REACHED();
                success = NO;
              }
            } else {
              DNOT_REACHED();
              success = NO;
            }
            ARC_RELEASE(_tmpPath);
            _tmpPath = nil;
          } else {
            NSData* data = [[NSData alloc] initWithBytes:(void*)dataBytes length:dataLength];
            GCDWebServerMultiPartArgument* argument = [[GCDWebServerMultiPartArgument alloc] initWithControlName:_controlName contentType:_contentType data:data];
            [_arguments addObject:argument];
            ARC_RELEASE(argument);
            ARC_RELEASE(data);
          }
        }
        
        if (subRange1.location != NSNotFound) {
          [_data replaceBytesInRange:NSMakeRange(0, subRange1.location + subRange1.length) withBytes:NULL length:0];
          _state = kParserState_Headers;
          success = [self _parseData];
        } else {
          _state = kParserState_End;
        }
      }
    } else {
      NSUInteger margin = 2 * _boundary.length;
      if (_data.length > margin) {
        NSUInteger length = _data.length - margin;
        if (_subParser) {
          if ([_subParser appendBytes:_data.bytes length:length]) {
            [_data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
          } else {
            DNOT_REACHED();
            success = NO;
          }
        } else if (_tmpPath) {
          ssize_t result = write(_tmpFile, _data.bytes, length);
          if (result == (ssize_t)length) {
            [_data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
          } else {
            DNOT_REACHED();
            success = NO;
          }
        }
      }
    }
  }
  
  return success;
}

- (BOOL)appendBytes:(const void*)bytes length:(NSUInteger)length {
  [_data appendBytes:bytes length:length];
  return [self _parseData];
}

- (BOOL)isAtEnd {
  return (_state == kParserState_End);
}

@end

@interface GCDWebServerMultiPartFormRequest () {
@private
  GCDWebServerMIMEStreamParser* _parser;
  NSMutableArray* _arguments;
  NSMutableArray* _files;
}
@end

@implementation GCDWebServerMultiPartFormRequest

@synthesize arguments=_arguments, files=_files;

+ (NSString*)mimeType {
  return @"multipart/form-data";
}

- (instancetype)initWithMethod:(NSString*)method url:(NSURL*)url headers:(NSDictionary*)headers path:(NSString*)path query:(NSDictionary*)query {
  if ((self = [super initWithMethod:method url:url headers:headers path:path query:query])) {
    _arguments = [[NSMutableArray alloc] init];
    _files = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)dealloc {
  ARC_RELEASE(_arguments);
  ARC_RELEASE(_files);
  
  ARC_DEALLOC(super);
}

- (BOOL)open:(NSError**)error {
  NSString* boundary = GCDWebServerExtractHeaderValueParameter(self.contentType, @"boundary");
  _parser = [[GCDWebServerMIMEStreamParser alloc] initWithBoundary:boundary defaultControlName:nil arguments:_arguments files:_files];
  if (_parser == nil) {
    *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed starting to parse multipart form data"}];
    return NO;
  }
  return YES;
}

- (BOOL)writeData:(NSData*)data error:(NSError**)error {
  if (![_parser appendBytes:data.bytes length:data.length]) {
    *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed continuing to parse multipart form data"}];
    return NO;
  }
  return YES;
}

- (BOOL)close:(NSError**)error {
  BOOL atEnd = [_parser isAtEnd];
  ARC_RELEASE(_parser);
  _parser = nil;
  if (!atEnd) {
    *error = [NSError errorWithDomain:kGCDWebServerErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed finishing to parse multipart form data"}];
    return NO;
  }
  return YES;
}

- (GCDWebServerMultiPartArgument*)firstArgumentForControlName:(NSString*)name {
  for (GCDWebServerMultiPartArgument* argument in _arguments) {
    if ([argument.controlName isEqualToString:name]) {
      return argument;
    }
  }
  return nil;
}

- (GCDWebServerMultiPartFile*)firstFileForControlName:(NSString*)name {
  for (GCDWebServerMultiPartFile* file in _files) {
    if ([file.controlName isEqualToString:name]) {
      return file;
    }
  }
  return nil;
}

- (NSString*)description {
  NSMutableString* description = [NSMutableString stringWithString:[super description]];
  if (_arguments.count) {
    [description appendString:@"\n"];
    for (GCDWebServerMultiPartArgument* argument in _arguments) {
      [description appendFormat:@"\n%@ (%@)\n", argument.controlName, argument.contentType];
      [description appendString:GCDWebServerDescribeData(argument.data, argument.contentType)];
    }
  }
  if (_files.count) {
    [description appendString:@"\n"];
    for (GCDWebServerMultiPartFile* file in _files) {
      [description appendFormat:@"\n%@ (%@): %@\n{%@}", file.controlName, file.contentType, file.fileName, file.temporaryPath];
    }
  }
  return description;
}

@end