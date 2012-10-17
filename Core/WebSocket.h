#import <Foundation/Foundation.h>

@class HTTPMessage;
@class GCDAsyncSocket;


#define WebSocketDidDieNotification  @"WebSocketDidDie"

// WebSocket message frame opcodes
#define WS_OPCODE_CONTINUATION		0
#define WS_OPCODE_TEXT				1
#define WS_OPCODE_BINARY			2

// WebSocket control frame opcodes
#define WS_OPCODE_CLOSE				8
#define WS_OPCODE_PING				9
#define WS_OPCODE_PONG				10

// Known WebSocket protocol versions
enum {
	WEBSOCKET_OLD_75,			// Old Hyxie versions
	WEBSOCKET_OLD_76,
	WEBSOCKET_VERSION_1,		// New Hybi versions
	WEBSOCKET_VERSION_2,
	WEBSOCKET_VERSION_3,
	WEBSOCKET_VERSION_4,
	WEBSOCKET_VERSION_5,
	WEBSOCKET_VERSION_6,
	WEBSOCKET_VERSION_7,
	WEBSOCKET_VERSION_8,		// implemented here
	WEBSOCKET_VERSION_9,
	WEBSOCKET_VERSION_10,
	WEBSOCKET_VERSION_11,
	WEBSOCKET_VERSION_12,
	WEBSOCKET_VERSION_13,
	WEBSOCKET_VERSION_14,
	WEBSOCKET_VERSION_15
};

// Main WebSocket class
@interface WebSocket : NSObject
{
	dispatch_queue_t websocketQueue;
	
	HTTPMessage *request;
	GCDAsyncSocket *asyncSocket;

	// message data when reading frames for protocolVersion >= WEBSOCKET_VERSION_1
	NSMutableData *message;
	UInt32 messageLength;		// this is the payloadLength value
	int messageOpcode;
	BOOL messageMasked;
	BOOL messageComplete;

	// data used when supporting old Hyxie versions 75 and 76
	NSData *term;
	
	BOOL isStarted;
	BOOL isOpen;
	int protocolVersion;
	
	id delegate;
}

@property (nonatomic, readonly) int protocolVersion;

+ (BOOL)isWebSocketRequest:(HTTPMessage *)request;

- (id)initWithRequest:(HTTPMessage *)request socket:(GCDAsyncSocket *)socket;

/**
 * Delegate option.
 * 
 * In most cases it will be easier to subclass WebSocket,
 * but some circumstances may lead one to prefer standard delegate callbacks instead.
**/
@property (/* atomic */ assign) id delegate;

/**
 * The WebSocket class is thread-safe, generally via it's GCD queue.
 * All public API methods are thread-safe,
 * and the subclass API methods are thread-safe as they are all invoked on the same GCD queue.
**/
@property (nonatomic, readonly) dispatch_queue_t websocketQueue;

/**
 * Public API
 * 
 * These methods are automatically called by the HTTPServer.
 * You may invoke the stop method yourself to close the WebSocket manually.
**/
- (void)start;
- (void)stop;

/**
 * Public API
 * 
 * Sends a message over the WebSocket.
 * These methods are thread-safe.
**/
- (void)sendMessage:(NSString *)msg;
- (void)sendBinaryMessage:(NSData *)msg;

// Low level frame sending. Can send a control frame using this method.
- (void)sendFrame:(int)opcode data:(NSData *)data;

/**
 * Subclass API
 * 
 * These methods are designed to be overriden by subclasses.
**/
- (void)didOpen;
- (void)didReceiveMessage:(NSString *)msg;
- (void)didReceiveBinaryMessage:(NSData *)msg;
- (void)didClose;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * There are two ways to create your own custom WebSocket:
 * 
 * - Subclass it and override the methods you're interested in.
 * - Use traditional delegate paradigm along with your own custom class.
 * 
 * They both exist to allow for maximum flexibility.
 * In most cases it will be easier to subclass WebSocket.
 * However some circumstances may lead one to prefer standard delegate callbacks instead.
 * One such example, you're already subclassing another class, so subclassing WebSocket isn't an option.
**/

@protocol WebSocketDelegate
@optional

- (void)webSocketDidOpen:(WebSocket *)ws;

- (void)webSocket:(WebSocket *)ws didReceiveMessage:(NSString *)msg;
- (void)webSocket:(WebSocket *)ws didReceiveBinaryMessage:(NSData *)msg;

- (void)webSocketDidClose:(WebSocket *)ws;

@end