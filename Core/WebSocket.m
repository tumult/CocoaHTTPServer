/*
 * WebSocket protocol implementation
 *
 * Supports old Hyxie protocol drafts 75 and 76
 * http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-76
 * Implementation by Deusty Designs
 *
 * Supports new Hybi protocol draft up to version 08
 * http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-08
 * This implementation does not FULLY implement the draft (i.e. cases where disconnection
 * from server with mandatory error code may not be implemented)
 * Current shortcomings:
 * - Data sizes are truncated to a 32 bit value. Anything bigger than 4GB received in one frame will be clipped.
 * - Could improve responses and errors sent to client
 * - Could add masking to outgoing frames
 * Implementation by Florent Pillet
 *
 */
#import "WebSocket.h"
#import "HTTPMessage.h"
#import "GCDAsyncSocket.h"
#import "DDNumber.h"
#import "DDData.h"
#import "HTTPLogging.h"

// Log levels: off, error, warn, info, verbose
// Other flags : trace
static const int httpLogLevel = HTTP_LOG_LEVEL_OFF;// | HTTP_LOG_FLAG_TRACE;

#define TIMEOUT_NONE          -1
#define TIMEOUT_REQUEST_BODY  10

#define TAG_HTTP_REQUEST_BODY		100
#define TAG_HTTP_RESPONSE_HEADERS	200
#define TAG_HTTP_RESPONSE_BODY		201
#define TAG_PREFIX					300
#define TAG_MSG_PLUS_SUFFIX			301

#define TAG_WS_FRAME_HEADER			302
#define TAG_WS_MASKED_PAYLOAD		305
#define TAG_WS_UNMASKED_PAYLOAD		306
#define TAG_WS_PAYLOAD_LENGTH		307


@interface WebSocket (PrivateAPI)

- (void)readVersion76RequestBody;
- (void)sendResponseBody;
- (void)sendResponseHeaders;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation WebSocket

@synthesize protocolVersion;

+ (BOOL)isWebSocketRequest:(HTTPMessage *)request
{	
	// Look for Upgrade: and Connection: headers.
	// If we find them, and they have the proper value,
	// we can safely assume this is a websocket request.
	
	NSString *upgradeHeaderValue = [request headerField:@"Upgrade"];
	NSString *connectionHeaderValue = [request headerField:@"Connection"];
	
	BOOL isWebSocket = YES;
	
	if (!upgradeHeaderValue || !connectionHeaderValue) {
		isWebSocket = NO;
	}
	else if (![upgradeHeaderValue caseInsensitiveCompare:@"WebSocket"] == NSOrderedSame) {
		isWebSocket = NO;
	}
	else if (![connectionHeaderValue caseInsensitiveCompare:@"Upgrade"] == NSOrderedSame) {
		isWebSocket = NO;
	}
	
	HTTPLogTrace2(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, (isWebSocket ? @"YES" : @"NO"));
	
	return isWebSocket;
}

+ (int)webSocketProtocolVersion:(HTTPMessage *)request
{
	// Check the request headers to determine the version of the WebSocket draft
	// the client is talking
	NSString *key = [request headerField:@"Sec-WebSocket-Key"];
	NSString *key1 = [request headerField:@"Sec-WebSocket-Key1"];
	NSString *key2 = [request headerField:@"Sec-WebSocket-Key2"];
	
	int vers = -1;

	if (key != nil)
	{
		// Client is talking the new Hybi protocol draft
		NSString *version = [request headerField:@"Sec-WebSocket-Version"];
		if (version != nil)
			vers = WEBSOCKET_VERSION_1 + [[version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] intValue] - 1;
	}
	if (vers == -1)
	{
		// Client is talking the old Hyxie protocol draft
		if (!key1 || !key2)
			vers = WEBSOCKET_OLD_75;
		else
			vers = WEBSOCKET_OLD_76;
	}
	
	HTTPLogTrace2(@"%@: %@ - %@ v%d", THIS_FILE, THIS_METHOD,
				  (vers <= WEBSOCKET_OLD_76) ? @"Old (Hyxie)" : @"New (Hybi)",
				  (vers <= WEBSOCKET_OLD_76) ? 75+vers-WEBSOCKET_OLD_75 : 1+vers-WEBSOCKET_VERSION_1);
	
	return vers;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Setup and Teardown
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize websocketQueue;

- (id)initWithRequest:(HTTPMessage *)aRequest socket:(GCDAsyncSocket *)socket
{
	HTTPLogTrace();
	
	if (aRequest == nil)
	{
		[self release];
		return nil;
	}
	
	if ((self = [super init]))
	{
		if (HTTP_LOG_VERBOSE)
		{
			NSData *requestHeaders = [aRequest messageData];
			
			NSString *temp = [[NSString alloc] initWithData:requestHeaders encoding:NSUTF8StringEncoding];
			HTTPLogVerbose(@"%@[%p] Request Headers:\n%@", THIS_FILE, self, temp);
			[temp release];
		}
		
		websocketQueue = dispatch_queue_create("WebSocket", NULL);
		request = [aRequest retain];
		
		asyncSocket = [socket retain];
		[asyncSocket setDelegate:self delegateQueue:websocketQueue];
		
		isOpen = NO;
		protocolVersion = [[self class] webSocketProtocolVersion:request];
		
		if (protocolVersion < WEBSOCKET_VERSION_1)
			term = [[NSData alloc] initWithBytes:"\xFF" length:1];
	}
	return self;
}

- (void)dealloc
{
	HTTPLogTrace();
	
	dispatch_release(websocketQueue);
	
	[request release];
	[message release];
	
	[asyncSocket setDelegate:nil delegateQueue:NULL];
	[asyncSocket disconnect];
	[asyncSocket release];
	
	[super dealloc];
}

- (id)delegate
{
	__block id result = nil;
	
	dispatch_sync(websocketQueue, ^{
		result = delegate;
	});
	
	return result;
}

- (void)setDelegate:(id)newDelegate
{
	dispatch_async(websocketQueue, ^{
		delegate = newDelegate;
	});
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Start and Stop
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Starting point for the WebSocket after it has been fully initialized (including subclasses).
 * This method is called by the HTTPConnection it is spawned from.
**/
- (void)start
{
	// This method is not exactly designed to be overriden.
	// Subclasses are encouraged to override the didOpen method instead.
	
	dispatch_async(websocketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		if (isStarted)
			return;
		isStarted = YES;
		
		if (protocolVersion == WEBSOCKET_OLD_76)
		{
			[self readVersion76RequestBody];
		}
		else
		{
			[self sendResponseHeaders];
			[self didOpen];
		}
		
		[pool drain];
	});
}

/**
 * This method is called by the HTTPServer if it is asked to stop.
 * The server, in turn, invokes stop on each WebSocket instance.
**/
- (void)stop
{
	// This method is not exactly designed to be overriden.
	// Subclasses are encouraged to override the didClose method instead.
	
	dispatch_async(websocketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		[asyncSocket disconnect];
		
		[pool drain];
	});
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark HTTP Response
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)readVersion76RequestBody
{
	HTTPLogTrace();
	
	//NSAssert(isVersion76, @"WebSocket version 75 doesn't contain a request body");
	
	[asyncSocket readDataToLength:8 withTimeout:TIMEOUT_NONE tag:TAG_HTTP_REQUEST_BODY];
}

- (NSString *)originResponseHeaderValue
{
	HTTPLogTrace();
	
	NSString *origin = [request headerField:@"Origin"];
	
	if (origin == nil)
	{
		NSString *port = [NSString stringWithFormat:@"%hu", [asyncSocket localPort]];
		
		return [NSString stringWithFormat:@"http://localhost:%@", port];
	}
	else
	{
		return origin;
	}
}

- (NSString *)locationResponseHeaderValue
{
	HTTPLogTrace();
	
	NSString *location;
	
	NSString *scheme = [asyncSocket isSecure] ? @"wss" : @"ws";
	NSString *host = [request headerField:@"Host"];
	
	NSString *requestUri = [[request url] relativeString];
	
	if (host == nil)
	{
		NSString *port = [NSString stringWithFormat:@"%hu", [asyncSocket localPort]];
		
		location = [NSString stringWithFormat:@"%@://localhost:%@%@", scheme, port, requestUri];
	}
	else
	{
		location = [NSString stringWithFormat:@"%@://%@%@", scheme, host, requestUri];
	}
	
	return location;
}


- (NSData *)processHyxieDraft76Key:(NSString *)key
{
	HTTPLogTrace();
	
	unichar c;
	NSUInteger i;
	NSUInteger length = [key length];
	
	// Concatenate the digits into a string,
	// and count the number of spaces.
	
	NSMutableString *numStr = [NSMutableString stringWithCapacity:10];
	long long numSpaces = 0;
	
	for (i = 0; i < length; i++)
	{
		c = [key characterAtIndex:i];
		
		if (c >= '0' && c <= '9')
		{
			[numStr appendFormat:@"%C", c];
		}
		else if (c == ' ')
		{
			numSpaces++;
		}
	}
	
	long long num = strtoll([numStr UTF8String], NULL, 10);
	
	long long resultHostNum;
	
	if (numSpaces == 0)
		resultHostNum = 0;
	else
		resultHostNum = num / numSpaces;
	
	HTTPLogVerbose(@"key(%@) -> %qi / %qi = %qi", key, num, numSpaces, resultHostNum);
	
	// Convert result to 4 byte big-endian (network byte order)
	// and then convert to raw data.
	
	UInt32 result = OSSwapHostToBigInt32((uint32_t)resultHostNum);
	
	return [NSData dataWithBytes:&result length:4];
}

- (void)sendHyxieDraft76ResponseBody:(NSData *)d3
{
	HTTPLogTrace();
	
	NSAssert(protocolVersion < WEBSOCKET_VERSION_1, @"New Hyxie protocol doesn't require a response body");
	NSAssert(protocolVersion == WEBSOCKET_OLD_76, @"WebSocket version 75 doesn't contain a response body");
	NSAssert([d3 length] == 8, @"Invalid requestBody length");
	
	NSString *key1 = [request headerField:@"Sec-WebSocket-Key1"];
	NSString *key2 = [request headerField:@"Sec-WebSocket-Key2"];
	
	NSData *d1 = [self processHyxieDraft76Key:key1];
	NSData *d2 = [self processHyxieDraft76Key:key2];
	
	// Concatenated d1, d2 & d3
	
	NSMutableData *d0 = [NSMutableData dataWithCapacity:(4+4+8)];
	[d0 appendData:d1];
	[d0 appendData:d2];
	[d0 appendData:d3];
	
	// Hash the data using MD5
	
	NSData *responseBody = [d0 md5Digest];
	
	[asyncSocket writeData:responseBody withTimeout:TIMEOUT_NONE tag:TAG_HTTP_RESPONSE_BODY];
	
	if (HTTP_LOG_VERBOSE)
	{
		NSString *s1 = [[NSString alloc] initWithData:d1 encoding:NSASCIIStringEncoding];
		NSString *s2 = [[NSString alloc] initWithData:d2 encoding:NSASCIIStringEncoding];
		NSString *s3 = [[NSString alloc] initWithData:d3 encoding:NSASCIIStringEncoding];
		
		NSString *s0 = [[NSString alloc] initWithData:d0 encoding:NSASCIIStringEncoding];
		
		NSString *sH = [[NSString alloc] initWithData:responseBody encoding:NSASCIIStringEncoding];
		
		HTTPLogVerbose(@"key1 result : raw(%@) str(%@)", d1, s1);
		HTTPLogVerbose(@"key2 result : raw(%@) str(%@)", d2, s2);
		HTTPLogVerbose(@"key3 passed : raw(%@) str(%@)", d3, s3);
		HTTPLogVerbose(@"key0 concat : raw(%@) str(%@)", d0, s0);
		HTTPLogVerbose(@"responseBody: raw(%@) str(%@)", responseBody, sH);
		
		[s1 release];
		[s2 release];
		[s3 release];
		[s0 release];
		[sH release];
	}
}

- (void)sendResponseHeaders
{
	HTTPLogTrace();
	
	HTTPMessage *wsResponse = [[HTTPMessage alloc] initResponseWithStatusCode:101
	                                                              description:@"Web Socket Protocol Handshake"
	                                                                  version:HTTPVersion1_1];
	
	[wsResponse setHeaderField:@"Upgrade" value:@"WebSocket"];
	[wsResponse setHeaderField:@"Connection" value:@"Upgrade"];
	
	
	if (protocolVersion < WEBSOCKET_VERSION_1)
	{
		// Note: It appears that WebSocket-Origin and WebSocket-Location
		// are required for Google's Chrome implementation to work properly.
		// 
		// If we don't send either header, Chrome will never report the WebSocket as open.
		// If we only send one of the two, Chrome will immediately close the WebSocket.
		// 
		// In addition to this it appears that Chrome's implementation is very picky of the values of the headers.
		// They have to match exactly with what Chrome sent us or it will close the WebSocket.
		NSString *originValue = [self originResponseHeaderValue];
		NSString *locationValue = [self locationResponseHeaderValue];
		
		NSString *originField = (protocolVersion >= WEBSOCKET_OLD_76) ? @"Sec-WebSocket-Origin" : @"WebSocket-Origin";
		NSString *locationField = (protocolVersion >= WEBSOCKET_OLD_76) ? @"Sec-WebSocket-Location" : @"WebSocket-Location";
		
		[wsResponse setHeaderField:originField value:originValue];
		[wsResponse setHeaderField:locationField value:locationValue];
	}
	if (protocolVersion >= WEBSOCKET_VERSION_1)
	{
		// Compute Sec-Websocket-Key according to Hybi draft protocol specification
		NSString *key = [[request headerField:@"Sec-Websocket-Key"] stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
		NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
		[wsResponse setHeaderField:@"Sec-Websocket-Accept" value:[[keyData sha1Digest] base64Encoded]];
	}

	NSData *responseHeaders = [wsResponse messageData];
	
	[wsResponse release];
	
	if (HTTP_LOG_VERBOSE)
	{
		NSString *temp = [[NSString alloc] initWithData:responseHeaders encoding:NSUTF8StringEncoding];
		HTTPLogVerbose(@"%@[%p] Response Headers:\n%@", THIS_FILE, self, temp);
		[temp release];
	}
	
	[asyncSocket writeData:responseHeaders withTimeout:TIMEOUT_NONE tag:TAG_HTTP_RESPONSE_HEADERS];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Core Functionality
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)didOpen
{
	HTTPLogTrace();
	
	// Override me to perform any custom actions once the WebSocket has been opened.
	// This method is invoked on the websocketQueue.
	// 
	// Don't forget to invoke [super didOpen] in your method.
	
	// Start reading for messages
	if (protocolVersion < WEBSOCKET_VERSION_1)
		[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:TAG_PREFIX];
	else
		[asyncSocket readDataToLength:2 withTimeout:TIMEOUT_NONE tag:TAG_WS_FRAME_HEADER];
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocketDidOpen:)])
	{
		[delegate webSocketDidOpen:self];
	}
}

- (void)sendFrame:(int)opcode data:(NSData *)data
{
	HTTPLogTrace();
	
	// Send a frame conforming to new Hybi protocol draft
	// Assemble a frame that's sent to the other end. We don't transmit multiple frames,
	// only single frames even for big messages
	NSUInteger length = [data length];
	NSUInteger headerLength;
	UInt8 payloadLengthByte;
	if (length < 126)
	{
		payloadLengthByte = (UInt8)length;
		headerLength = 2;
	}
	else if (length < 0x10000)
	{
		payloadLengthByte = 126;
		headerLength = 4;			// 2 header bytes + 2 length bytes
	}
	else
	{
		payloadLengthByte = 127;
		headerLength = 10;			// 2 header bytes + 8 length bytes
	}
	NSMutableData *msg = [[NSMutableData alloc] initWithLength:headerLength + length];
	UInt8 *frame = (UInt8 *)[msg mutableBytes];
	*frame++ = 0x80 | opcode;			// FIN + opcode
	*frame++ = payloadLengthByte;
	if (payloadLengthByte == 126)
	{
		*frame++ = (UInt8)(length >> 8);
		*frame++ = (UInt8)length;
	}
	else if (payloadLengthByte == 127)
	{
		*frame++ = 0;
		*frame++ = 0;
		*frame++ = 0;
		*frame++ = 0;
		*frame++ = (UInt8)(length >> 24);
		*frame++ = (UInt8)(length >> 16);
		*frame++ = (UInt8)(length >> 8);
		*frame++ = (UInt8)length;
	}
	if (length)
		memcpy(frame, [data bytes], length);
	[asyncSocket writeData:msg withTimeout:TIMEOUT_NONE tag:0];
	[msg release];
}

- (void)sendMessage:(NSString *)msg
{
	HTTPLogTrace();
	
	if (protocolVersion < WEBSOCKET_VERSION_1)
	{
		NSData *msgData = [msg dataUsingEncoding:NSUTF8StringEncoding];
		
		NSMutableData *data = [NSMutableData dataWithCapacity:([msgData length] + 2)];
		
		[data appendBytes:"\x00" length:1];
		[data appendData:msgData];
		[data appendBytes:"\xFF" length:1];
		
		// Remember: GCDAsyncSocket is thread-safe
		
		[asyncSocket writeData:data withTimeout:TIMEOUT_NONE tag:0];
	}
	else
	{
		[self sendFrame:WS_OPCODE_TEXT data:[msg dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

- (void)sendBinaryMessage:(NSData *)msg
{
	HTTPLogTrace();

	NSAssert(protocolVersion >= WEBSOCKET_VERSION_1, @"Old WebSocket versions 75 and 76 don't support binary data");
	
	[self sendFrame:WS_OPCODE_BINARY data:msg];
}

- (void)didReceiveMessage:(NSString *)msg
{
	HTTPLogTrace();
	
	// Override me to process incoming messages.
	// This method is invoked on the websocketQueue.
	// 
	// For completeness, you should invoke [super didReceiveMessage:msg] in your method.
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocket:didReceiveMessage:)])
	{
		[delegate webSocket:self didReceiveMessage:msg];
	}
}

- (void)didReceiveBinaryMessage:(NSData *)msg
{
	HTTPLogTrace();
	
	// Override me to process incoming messages.
	// This method is invoked on the websocketQueue.
	// 
	// For completeness, you should invoke [super didReceiveMessage:msg] in your method.
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocket:didReceiveBinaryMessage:)])
	{
		[delegate webSocket:self didReceiveBinaryMessage:msg];
	}
}

- (void)didClose
{
	HTTPLogTrace();
	
	// Override me to perform any cleanup when the socket is closed
	// This method is invoked on the websocketQueue.
	// 
	// Don't forget to invoke [super didClose] at the end of your method.
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocketDidClose:)])
	{
		[delegate webSocketDidClose:self];
	}
	
	// Notify HTTPServer
	[[NSNotificationCenter defaultCenter] postNotificationName:WebSocketDidDieNotification object:self];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark AsyncSocket Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
	HTTPLogTrace();
	
	if (tag == TAG_HTTP_REQUEST_BODY)
	{
		// Old Hyxie protocol draft version 76
		[self sendResponseHeaders];
		[self sendHyxieDraft76ResponseBody:data];
		[self didOpen];
	}
	else if (tag == TAG_PREFIX)
	{
		// Old Hyxie protocol draft
		UInt8 *pFrame = (UInt8 *)[data bytes];
		UInt8 frame = *pFrame;
		
		if (frame <= 0x7F)
		{
			[asyncSocket readDataToData:term withTimeout:TIMEOUT_NONE tag:TAG_MSG_PLUS_SUFFIX];
		}
		else
		{
			// Unsupported frame type
			[asyncSocket disconnect];
		}
	}
	else if (tag == TAG_WS_FRAME_HEADER)
	{
		UInt8 *header = (UInt8 *)[data bytes];
		UInt8 opcode = *header++;
		UInt8 payloadLength = *header;
		BOOL masked = (payloadLength & 0x80) == 0x80;
		messageComplete = (opcode & 0x80) == 0x80;
		messageLength = payloadLength & 0x7f;
		opcode &= 0x0f;
		switch (opcode)
		{
			case WS_OPCODE_CONTINUATION:
				// just add to the current data
				break;

			case WS_OPCODE_PING:
			case WS_OPCODE_TEXT:
			case WS_OPCODE_BINARY:
				messageOpcode = opcode;
				messageMasked = masked;
				if (message != nil)
				{
					// we should be receiving a continuation if a fragment already existed: discard the current fragment
					[message setLength:0];
				}
				else
					message = [[NSMutableData alloc] init];
				break;
				
			case WS_OPCODE_CLOSE:
				[asyncSocket disconnect];
				break;
				
			default:
				// Unsupported opcode: read next message
				[asyncSocket readDataToLength:2 withTimeout:TIMEOUT_NONE tag:TAG_WS_FRAME_HEADER];
				break;
		}
		
		// TODO: spec says that client MUST mask messages, and that connection should close
		// when receiving an unmasked message

		// determine payload length
		if (messageLength < 126)
		{
			if (masked)
				[asyncSocket readDataToLength:4+messageLength withTimeout:TIMEOUT_NONE tag:TAG_WS_MASKED_PAYLOAD];
			else
				[asyncSocket readDataToLength:messageLength withTimeout:TIMEOUT_NONE tag:TAG_WS_UNMASKED_PAYLOAD];
		}
		else if (messageLength == 126)
			[asyncSocket readDataToLength:2 withTimeout:TIMEOUT_NONE tag:TAG_WS_PAYLOAD_LENGTH];
		else
			[asyncSocket readDataToLength:8 withTimeout:TIMEOUT_NONE tag:TAG_WS_PAYLOAD_LENGTH];
	}
	else if (tag == TAG_WS_PAYLOAD_LENGTH)
	{
		// receiving a payload length that's either 16 or 64 bit: extract it (only care about the last 32 bits, really)
		UInt8 *p = (UInt8 *)[data bytes];
		UInt32 length;
		if (messageLength == 126)
			length = ((UInt32)p[0] << 8) | (UInt32)p[1];
		else
			length = ((UInt32)p[4] << 24) | ((UInt32)p[5] << 16) | ((UInt32)p[6] << 8) | (UInt32)p[7];
		messageLength = length;
		if (messageMasked)
			[asyncSocket readDataToLength:4+messageLength withTimeout:TIMEOUT_NONE tag:TAG_WS_MASKED_PAYLOAD];
		else
			[asyncSocket readDataToLength:messageLength withTimeout:TIMEOUT_NONE tag:TAG_WS_UNMASKED_PAYLOAD];
	}
	else if (tag == TAG_WS_MASKED_PAYLOAD || tag == TAG_WS_UNMASKED_PAYLOAD)
	{
		// process payload contents with optional 4 bytes mask
		if (tag == TAG_WS_MASKED_PAYLOAD)
		{
			// Unmask data according to specification
			NSMutableData *finalData = [[NSMutableData alloc] initWithLength:messageLength];
			UInt8 *p = (UInt8 *)[data bytes];
			UInt8 *q = p + 4;
			UInt8 *r = (UInt8 *)[finalData mutableBytes];
			for (UInt32 i=0; i < messageLength; i++)
				*r++ = *q++ ^ p[i & 0x03];
			data = [finalData autorelease];
		}
		[message appendData:data];
		if (messageComplete)
		{
			if (messageOpcode == WS_OPCODE_TEXT)
			{
				NSString *msg = [[NSString alloc] initWithBytes:[data bytes] length:[data length] encoding:NSUTF8StringEncoding];
				[self didReceiveMessage:msg];
				[msg release];
			}
			else if (messageOpcode == WS_OPCODE_BINARY)
			{
				[self didReceiveBinaryMessage:data];
			}
			else if (messageOpcode == WS_OPCODE_PING)
			{
				[self sendFrame:WS_OPCODE_PONG data:message];
			}
		}

		// Read next message (we are in the case WEBSOCKET_VERSION_1 or later, always read first two bytes of a frame)
		[asyncSocket readDataToLength:2 withTimeout:TIMEOUT_NONE tag:TAG_WS_FRAME_HEADER];
	}
	else
	{
		// Frame contents for old Hyxie protocol versions 75 / 76
		NSUInteger msgLength = [data length] - 1; // Excluding ending 0xFF frame

		NSString *msg = [[NSString alloc] initWithBytes:[data bytes] length:msgLength encoding:NSUTF8StringEncoding];
		
		[self didReceiveMessage:msg];
		
		[msg release];
		
		// Read next message
		[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:TAG_PREFIX];
	}
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
	HTTPLogTrace2(@"%@[%p]: socketDidDisconnect:withError: %@", THIS_FILE, self, error);
	
	[self didClose];
}

@end
