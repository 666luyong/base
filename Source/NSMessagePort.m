/** Implementation of network port object based on unix domain sockets
   Copyright (C) 2000 Free Software Foundation, Inc.
   
   Written by:  Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Based on code by:  Andrew Kachites McCallum <mccallum@gnu.ai.mit.edu>
   
   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
   
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
   */ 

#include "config.h"
#include "GNUstepBase/preface.h"
#include "GNUstepBase/GSLock.h"
#include "Foundation/NSArray.h"
#include "Foundation/NSNotification.h"
#include "Foundation/NSException.h"
#include "Foundation/NSRunLoop.h"
#include "Foundation/NSByteOrder.h"
#include "Foundation/NSData.h"
#include "Foundation/NSDate.h"
#include "Foundation/NSMapTable.h"
#include "Foundation/NSPortMessage.h"
#include "Foundation/NSPortNameServer.h"
#include "Foundation/NSLock.h"
#include "Foundation/NSThread.h"
#include "Foundation/NSConnection.h"
#include "Foundation/NSDebug.h"
#include "Foundation/NSPathUtilities.h"
#include "Foundation/NSValue.h"
#include "Foundation/NSFileManager.h"
#include "Foundation/NSProcessInfo.h"
#include <stdio.h>
#include <stdlib.h>
#ifdef HAVE_UNISTD_H
#include <unistd.h>		/* for gethostname() */
#endif

#ifndef __MINGW__
#include <sys/param.h>		/* for MAXHOSTNAMELEN */
#include <sys/types.h>
#include <sys/un.h>
#include <arpa/inet.h>		/* for inet_ntoa() */
#endif /* !__MINGW__ */
#include <errno.h>
#include <limits.h>
#include <string.h>		/* for strchr() */
#include <ctype.h>		/* for strchr() */
#include <fcntl.h>
#ifdef __MINGW__
#include <winsock2.h>
#include <wininet.h>
#include <process.h>
#include <sys/time.h>
#else
#include <sys/time.h>
#include <sys/resource.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
/*
 *	Stuff for setting the sockets into non-blocking mode.
 */
#ifdef	__POSIX_SOURCE
#define NBLK_OPT     O_NONBLOCK
#else
#define NBLK_OPT     FNDELAY
#endif

#include <netinet/in.h>
#include <net/if.h>
#if	!defined(SIOCGIFCONF) || defined(__CYGWIN__)
#include <sys/ioctl.h>
#ifndef	SIOCGIFCONF
#include <sys/sockio.h>
#endif
#endif

#if	defined(__svr4__)
#include <sys/stropts.h>
#endif
#endif /* !__MINGW__ */

#ifdef __MINGW__
#define close closesocket
#endif

/* Older systems (Solaris) compatibility */
#ifndef AF_LOCAL
#define AF_LOCAL AF_UNIX
#define PF_LOCAL PF_UNIX
#endif
#ifndef SUN_LEN
#define SUN_LEN(su) \
	(sizeof(*(su)) - sizeof((su)->sun_path) + strlen((su)->sun_path))
#endif

/*
 * Largest chunk of data possible in DO
 */
static gsu32	maxDataLength = 10 * 1024 * 1024;

#if 0
#define	M_LOCK(X) {NSDebugMLLog(@"NSMessagePort",@"lock %@",X); [X lock];}
#define	M_UNLOCK(X) {NSDebugMLLog(@"NSMessagePort",@"unlock %@",X); [X unlock];}
#else
#define	M_LOCK(X) {[X lock];}
#define	M_UNLOCK(X) {[X unlock];}
#endif

#define	GS_CONNECTION_MSG	0
#define	NETBLOCK	8192

#ifndef INADDR_NONE
#define	INADDR_NONE	-1
#endif

/*
 * Theory of operation
 *
 * 
 */


/* Private interfaces */

/*
 * The GSPortItemType constant is used to identify the type of data in
 * each packet read.  All data transmitted is in a packet, each packet
 * has an initial packet type and packet length.
 */
typedef	enum {
  GSP_NONE,
  GSP_PORT,		/* Simple port item.			*/
  GSP_DATA,		/* Simple data item.			*/
  GSP_HEAD		/* Port message header + initial data.	*/
} GSPortItemType;

/*
 * The GSPortItemHeader structure defines the header for each item transmitted.
 * Its contents are transmitted in network byte order.
 */
typedef struct {
  gsu32	type;		/* A GSPortItemType as a 4-byte number.		*/
  gsu32	length;		/* The length of the item (excluding header).	*/
} GSPortItemHeader;

/*
 * The GSPortMsgHeader structure is at the start of any item of type GSP_HEAD.
 * Its contents are transmitted in network byte order.
 * Any additional data in the item is an NSData object.
 * NB. additional data counts as part of the same item.
 */
typedef struct {
  gsu32	mId;		/* The ID for the message starting with this.	*/
  gsu32	nItems;		/* Number of items (including this one).	*/
} GSPortMsgHeader;

typedef	struct {
  char	version;
  char	addr[0];	/* name of the socket in the port directory */
} GSPortInfo;

/*
 * Here is how data is transmitted over a socket -
 * Initially the process making the connection sends an item of type
 * GSP_PORT to tell the remote end what port is connecting to it.
 * Therafter, all communication is via port messages.  Each port message
 * consists of an item of type GSP_HEAD followed by zero or more items
 * of type GSP_PORT or GSP_DATA.  The number of items in a port message
 * is encoded in the 'nItems' field of the header.
 */

typedef enum {
  GS_H_UNCON = 0,	// Currently idle and unconnected.
  GS_H_TRYCON,		// Trying connection (outgoing).
  GS_H_ACCEPT,		// Making initial connection (incoming).
  GS_H_CONNECTED	// Currently connected.
} GSHandleState;

@interface GSMessageHandle : NSObject <GCFinalization, RunLoopEvents>
{
  int			desc;		/* File descriptor for I/O.	*/
  unsigned		wItem;		/* Index of item being written.	*/
  NSMutableData		*wData;		/* Data object being written.	*/
  unsigned		wLength;	/* Ammount written so far.	*/
  NSMutableArray	*wMsgs;		/* Message in progress.		*/
  NSMutableData		*rData;		/* Buffer for incoming data	*/
  gsu32			rLength;	/* Amount read so far.		*/
  gsu32			rWant;		/* Amount desired.		*/
  NSMutableArray	*rItems;	/* Message in progress.		*/
  GSPortItemType	rType;		/* Type of data being read.	*/
  gsu32			rId;		/* Id of incoming message.	*/
  unsigned		nItems;		/* Number of items to be read.	*/
  GSHandleState		state;		/* State of the handle.		*/
  unsigned int		addrNum;	/* Address number within host.	*/
@public
  NSRecursiveLock	*myLock;	/* Lock for this handle.	*/
  BOOL			caller;		/* Did we connect to other end?	*/
  BOOL			valid;
  NSMessagePort		*recvPort;
  NSMessagePort		*sendPort;
  struct sockaddr_un 	sockAddr;	/* Far end of connection.	*/
}

+ (GSMessageHandle*) handleWithDescriptor: (int)d;
- (BOOL) connectToPort: (NSMessagePort*)aPort beforeDate: (NSDate*)when;
- (int) descriptor;
- (void) invalidate;
- (BOOL) isValid;
- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode;
- (NSMessagePort*) recvPort;
- (BOOL) sendMessage: (NSArray*)components beforeDate: (NSDate*)when;
- (NSMessagePort*) sendPort;
- (void) setState: (GSHandleState)s;
- (GSHandleState) state;
- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode;
@end


/*
 * Utility functions for encoding and decoding ports.
 */
static NSMessagePort*
decodePort(NSData *data)
{
  GSPortItemHeader	*pih;
  GSPortInfo		*pi;
  
  pih = (GSPortItemHeader*)[data bytes];
  NSCAssert(GSSwapBigI32ToHost(pih->type) == GSP_PORT,
    NSInternalInconsistencyException);
  pi = (GSPortInfo*)&pih[1];
  if (pi->version != 0)
    {
      NSLog(@"Remote version of GNUstep is more recent than this one (%i)",
	pi->version);
      return nil;
    }

  NSDebugFLLog(@"NSMessagePort", @"Decoded port as '%s'", pi->addr);

  return [NSMessagePort _portWithName: pi->addr
			     listener: NO];
}

static NSData*
newDataWithEncodedPort(NSMessagePort *port)
{
  GSPortItemHeader	*pih;
  GSPortInfo		*pi;
  NSMutableData		*data;
  unsigned		plen;
  const unsigned char	*name = [port _name];

  plen = 2 + strlen(name);
  
  data = [[NSMutableData alloc] initWithLength: sizeof(GSPortItemHeader)+plen];
  pih = (GSPortItemHeader*)[data mutableBytes];
  pih->type = GSSwapHostI32ToBig(GSP_PORT);
  pih->length = GSSwapHostI32ToBig(plen);
  pi = (GSPortInfo*)&pih[1];
  strcpy(pi->addr, name);

  NSDebugFLLog(@"NSMessagePort", @"Encoded port as '%s'", pi->addr);

  return data;
}



@implementation	GSMessageHandle

static Class	mutableArrayClass;
static Class	mutableDataClass;
static Class	portMessageClass;
static Class	runLoopClass;


+ (id) allocWithZone: (NSZone*)zone
{
  [NSException raise: NSGenericException
	      format: @"attempt to alloc a GSMessageHandle!"];
  return nil;
}

+ (GSMessageHandle*) handleWithDescriptor: (int)d
{
  GSMessageHandle	*handle;
#ifdef __MINGW__
  unsigned long dummy;
#else
  int		e;
#endif /* __MINGW__ */

  if (d < 0)
    {
      NSLog(@"illegal descriptor (%d) for message handle", d);
      return nil;
    }
#ifdef __MINGW__
  dummy = 1;
  if (ioctlsocket(d, FIONBIO, &dummy) < 0)
    {
      NSLog(@"unable to set non-blocking mode on %d - %s",
	d, GSLastErrorStr(errno));
      return nil;
    }
#else /* !__MINGW__ */
  if ((e = fcntl(d, F_GETFL, 0)) >= 0)
    {
      e |= NBLK_OPT;
      if (fcntl(d, F_SETFL, e) < 0)
	{
	  NSLog(@"unable to set non-blocking mode on %d - %s",
	    d, GSLastErrorStr(errno));
	  return nil;
	}
    }
  else
    {
      NSLog(@"unable to get non-blocking mode on %d - %s",
	d, GSLastErrorStr(errno));
      return nil;
    }
#endif
  handle = (GSMessageHandle*)NSAllocateObject(self, 0, NSDefaultMallocZone());
  handle->desc = d;
  handle->wMsgs = [NSMutableArray new];
  handle->myLock = [GSLazyRecursiveLock new];
  handle->valid = YES;
  return AUTORELEASE(handle);
}

+ (void) initialize
{
  if (self == [GSMessageHandle class])
    {
#ifdef __MINGW__
      WORD wVersionRequested;
      WSADATA wsaData;

      wVersionRequested = MAKEWORD(2, 0);
      WSAStartup(wVersionRequested, &wsaData);
#endif
      mutableArrayClass = [NSMutableArray class];
      mutableDataClass = [NSMutableData class];
      portMessageClass = [NSPortMessage class];
      runLoopClass = [NSRunLoop class];
    }
}

- (BOOL) connectToPort: (NSMessagePort*)aPort beforeDate: (NSDate*)when
{
  NSRunLoop		*l;
  const unsigned char *name;

  M_LOCK(myLock);
  NSDebugMLLog(@"NSMessagePort", @"Connecting on 0x%x in thread 0x%x before %@",
    self, GSCurrentThread(), when);
  if (state != GS_H_UNCON)
    {
      BOOL	result;

      if (state == GS_H_CONNECTED)	/* Already connected.	*/
	{
	  NSLog(@"attempting connect on connected handle");
	  result = YES;
	}
      else if (state == GS_H_ACCEPT)	/* Impossible.	*/
	{
	  NSLog(@"attempting connect with accepting handle");
	  result = NO;
	}
      else				/* Already connecting.	*/
	{
	  NSLog(@"attempting connect while connecting");
	  result = NO;
	}
      M_UNLOCK(myLock);
      return result;
    }

  if (recvPort == nil || aPort == nil)
    {
      NSLog(@"attempting connect with port(s) unset");
      M_UNLOCK(myLock);
      return NO;	/* impossible.		*/
    }


  name = [aPort _name];
  memset(&sockAddr, '\0', sizeof(sockAddr));
  sockAddr.sun_family = AF_LOCAL;
  strncpy(sockAddr.sun_path, name, sizeof(sockAddr.sun_path));

  if (connect(desc, (struct sockaddr*)&sockAddr, SUN_LEN(&sockAddr)) < 0)
    {
#ifdef __MINGW__
      if (WSAGetLastError() != WSAEWOULDBLOCK)
#else
      if (errno != EINPROGRESS)
#endif
	{
	  NSLog(@"unable to make connection to %s - %s",
	    sockAddr.sun_path,
	    GSLastErrorStr(errno));
	  M_UNLOCK(myLock);
	  return NO;
	}
    }

  state = GS_H_TRYCON;
  l = [NSRunLoop currentRunLoop];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_WDESC
      watcher: self
      forMode: NSConnectionReplyMode];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_EDESC
      watcher: self
      forMode: NSConnectionReplyMode];

  while (valid == YES && state == GS_H_TRYCON
    && [when timeIntervalSinceNow] > 0)
    {
      [l runMode: NSConnectionReplyMode beforeDate: when];
    }

  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_WDESC
	 forMode: NSConnectionReplyMode
	     all: NO];
  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_EDESC
	 forMode: NSConnectionReplyMode
	     all: NO];

  if (state == GS_H_TRYCON)
    {
      state = GS_H_UNCON;
      addrNum = 0;
      M_UNLOCK(myLock);
      return NO;	/* Timed out 	*/
    }
  else if (state == GS_H_UNCON)
    {
      addrNum = 0;
      state = GS_H_UNCON;
      M_UNLOCK(myLock);
      return NO;
    }
  else
    {
      addrNum = 0;
      caller = YES;
      [aPort addHandle: self forSend: YES];
      M_UNLOCK(myLock);
      return YES;
    }
}

- (void) dealloc
{
  [self gcFinalize];
  DESTROY(rData);
  DESTROY(rItems);
  DESTROY(wMsgs);
  DESTROY(myLock);
  [super dealloc];
}

- (NSString*) description
{
  return [NSString stringWithFormat: @"<GSMessageHandle %p (%d) to %s>",
    self, desc, sockAddr.sun_path];
}

- (int) descriptor
{
  return desc;
}

- (void) gcFinalize
{
  [self invalidate];
  (void)close(desc);
  desc = -1;
}

- (void) invalidate
{
  if (valid == YES)
    {
      M_LOCK(myLock);
      if (valid == YES)
	{ 
	  NSRunLoop	*l;

	  valid = NO;
	  l = [runLoopClass currentRunLoop];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_RDESC
		 forMode: nil
		     all: YES];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_WDESC
		 forMode: nil
		     all: YES];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_EDESC
		 forMode: nil
		     all: YES];
	  NSDebugMLLog(@"NSMessagePort", @"invalidated 0x%x in thread 0x%x",
	    self, GSCurrentThread());
	  [[self recvPort] removeHandle: self];
	  [[self sendPort] removeHandle: self];
	}
      M_UNLOCK(myLock);
    }
}

- (BOOL) isValid
{
  return valid;
}

- (NSMessagePort*) recvPort
{
  if (recvPort == nil)
    return nil;
  else
    return GS_GC_UNHIDE(recvPort);
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode
{
  NSDebugMLLog(@"NSMessagePort_details", @"received %s event on 0x%x in thread 0x%x",
    type == ET_RPORT ? "read" : "write", self, GSCurrentThread());
  /*
   * If we have been invalidated (desc < 0) then we should ignore this
   * event and remove ourself from the runloop.
   */
  if (desc < 0)
    {
      NSRunLoop	*l = [runLoopClass currentRunLoop];

      [l removeEvent: data
		type: ET_WDESC
	     forMode: mode
		 all: YES];
      [l removeEvent: data
		type: ET_EDESC
	     forMode: mode
		 all: YES];
      return;
    }

  M_LOCK(myLock);

  if (type == ET_RPORT)
    {
      unsigned	want;
      void	*bytes;
      int	res;

      /*
       * Make sure we have a buffer big enough to hold all the data we are
       * expecting, or NETBLOCK bytes, whichever is greater.
       */
      if (rData == nil)
	{
	  rData = [[mutableDataClass alloc] initWithLength: NETBLOCK];
	  rWant = sizeof(GSPortItemHeader);
	  rLength = 0;
	  want = NETBLOCK;
	}
      else
	{
	  want = [rData length];
	  if (want < rWant)
	    {
	      want = rWant;
	      [rData setLength: want];
	    }
	  if (want < NETBLOCK)
	    {
	      want = NETBLOCK;
	      [rData setLength: want];
	    }
	}

      /*
       * Now try to fill the buffer with data.
       */
      bytes = [rData mutableBytes];
#ifdef __MINGW__
      res = recv(desc, bytes + rLength, want - rLength, 0);
#else
      res = read(desc, bytes + rLength, want - rLength);
#endif
      if (res <= 0)
	{
	  if (res == 0)
	    {
	      NSDebugMLLog(@"NSMessagePort", @"read eof on 0x%x in thread 0x%x",
		self, GSCurrentThread());
	      M_UNLOCK(myLock);
	      [self invalidate];
	      return;
	    }
	  else if (errno != EINTR && errno != EAGAIN)
	    {
	      NSDebugMLLog(@"NSMessagePort",
		@"read failed - %s on 0x%x in thread 0x%x",
		GSLastErrorStr(errno), self, GSCurrentThread());
	      M_UNLOCK(myLock);
	      [self invalidate];
	      return;
	    }
	  res = 0;	/* Interrupted - continue	*/
	}
      NSDebugMLLog(@"NSMessagePort_details", @"read %d bytes on 0x%x in thread 0x%x",
	res, self, GSCurrentThread());
      rLength += res;

      while (valid == YES && rLength >= rWant)
	{
	  BOOL	shouldDispatch = NO;

	  switch (rType)
	    {
	      case GSP_NONE:
		{
		  GSPortItemHeader	*h;
		  unsigned		l;

		  /*
		   * We have read an item header - set up to read the
		   * remainder of the item.
		   */
		  h = (GSPortItemHeader*)bytes;
		  rType = GSSwapBigI32ToHost(h->type);
		  l = GSSwapBigI32ToHost(h->length);
		  if (rType == GSP_PORT)
		    {
		      if (l > 512)
			{
			  NSLog(@"%@ - unreasonable length (%u) for port",
			    self, l);
			  M_UNLOCK(myLock);
			  [self invalidate];
			  return;
			}
		      /*
		       * For a port, we leave the item header in the data
		       * so that our decode function can check length info.
		       */
		      rWant += l;
		    }
		  else if (rType == GSP_DATA)
		    {
		      if (l == 0)
			{
			  NSData	*d;

			  /*
			   * For a zero-length data chunk, we create an empty
			   * data object and add it to the current message.
			   */
			  rType = GSP_NONE;	/* ready for a new item	*/
			  rLength -= rWant;
			  if (rLength > 0)
			    {
			      memmove(bytes, bytes + rWant, rLength);
			    }
			  rWant = sizeof(GSPortItemHeader);
			  d = [mutableDataClass new];
			  [rItems addObject: d];
			  RELEASE(d);
			  if (nItems == [rItems count])
			    {
			      shouldDispatch = YES;
			    }
			}
		      else
			{
			  if (l > maxDataLength)
			    {
			      NSLog(@"%@ - unreasonable length (%u) for data",
				self, l);
			      M_UNLOCK(myLock);
			      [self invalidate];
			      return;
			    }
			  /*
			   * If not a port or zero length data,
			   * we discard the data read so far and fill the
			   * data object with the data item from the msg.
			   */
			  rLength -= rWant;
			  if (rLength > 0)
			    {
			      memmove(bytes, bytes + rWant, rLength);
			    }
			  rWant = l;
			}
		    }
		  else if (rType == GSP_HEAD)
		    {
		      if (l > maxDataLength)
			{
			  NSLog(@"%@ - unreasonable length (%u) for data",
			    self, l);
			  M_UNLOCK(myLock);
			  [self invalidate];
			  return;
			}
		      /*
		       * If not a port or zero length data,
		       * we discard the data read so far and fill the
		       * data object with the data item from the msg.
		       */
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memmove(bytes, bytes + rWant, rLength);
			}
		      rWant = l;
		    }
		  else
		    {
		      NSLog(@"%@ - bad data received on port handle, rType=%i", self, rType);
		      M_UNLOCK(myLock);
		      [self invalidate];
		      return;
		    }
		}
		break;

	      case GSP_HEAD:
		{
		  GSPortMsgHeader	*h;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  /*
		   * We have read a message header - set up to read the
		   * remainder of the message.
		   */
		  h = (GSPortMsgHeader*)bytes;
		  rId = GSSwapBigI32ToHost(h->mId);
		  nItems = GSSwapBigI32ToHost(h->nItems);
		  NSAssert(nItems >0, NSInternalInconsistencyException);
		  rItems
		    = [mutableArrayClass allocWithZone: NSDefaultMallocZone()];
		  rItems = [rItems initWithCapacity: nItems];
		  if (rWant > sizeof(GSPortMsgHeader))
		    {
		      NSData	*d;

		      /*
		       * The first data item of the message was included in
		       * the header - so add it to the rItems array.
		       */
		      rWant -= sizeof(GSPortMsgHeader);
		      d = [mutableDataClass alloc];
		      d = [d initWithBytes: bytes + sizeof(GSPortMsgHeader)
				    length: rWant];
		      [rItems addObject: d];
		      RELEASE(d);
		      rWant += sizeof(GSPortMsgHeader);
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memmove(bytes, bytes + rWant, rLength);
			}
		      rWant = sizeof(GSPortItemHeader);
		      if (nItems == 1)
			{
			  shouldDispatch = YES;
			}
		    }
		  else
		    {
		      /*
		       * want to read another item
		       */
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memmove(bytes, bytes + rWant, rLength);
			}
		      rWant = sizeof(GSPortItemHeader);
		    }
		}
		break;

	      case GSP_DATA:
		{
		  NSData	*d;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  d = [mutableDataClass allocWithZone: NSDefaultMallocZone()];
		  d = [d initWithBytes: bytes length: rWant];
		  [rItems addObject: d];
		  RELEASE(d);
		  rLength -= rWant;
		  if (rLength > 0)
		    {
		      memmove(bytes, bytes + rWant, rLength);
		    }
		  rWant = sizeof(GSPortItemHeader);
		  if (nItems == [rItems count])
		    {
		      shouldDispatch = YES;
		    }
		}
		break;

	      case GSP_PORT:
		{
		  NSMessagePort	*p;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  p = decodePort(rData);
		  if (p == nil)
		    {
		      NSLog(@"%@ - unable to decode remote port", self);
		      M_UNLOCK(myLock);
		      [self invalidate];
		      return;
		    }
		  /*
		   * Set up to read another item header.
		   */
		  rLength -= rWant;
		  if (rLength > 0)
		    {
		      memmove(bytes, bytes + rWant, rLength);
		    }
		  rWant = sizeof(GSPortItemHeader);

		  if (state == GS_H_ACCEPT)
		    {
		      /*
		       * This is the initial port information on a new
		       * connection - set up port relationships.
		       */
		      state = GS_H_CONNECTED;
		      [p addHandle: self forSend: YES];
		    }
		  else
		    {
		      /*
		       * This is a port within a port message - add
		       * it to the message components.
		       */
		      [rItems addObject: p];
		      if (nItems == [rItems count])
			{
			  shouldDispatch = YES;
			}
		    }
		}
		break;
	    }

	  if (shouldDispatch == YES)
	    {
	      NSPortMessage	*pm;
	      NSMessagePort		*rp = [self recvPort];

	      pm = [portMessageClass allocWithZone: NSDefaultMallocZone()];
	      pm = [pm initWithSendPort: [self sendPort]
			    receivePort: rp
			     components: rItems];
	      [pm setMsgid: rId];
	      rId = 0;
	      DESTROY(rItems);
	      NSDebugMLLog(@"NSMessagePort_details",
		@"got message %@ on 0x%x in thread 0x%x",
		pm, self, GSCurrentThread());
	      RETAIN(rp);
	      M_UNLOCK(myLock);
	      NS_DURING
		{
		  [rp handlePortMessage: pm];
		}
	      NS_HANDLER
		{
		  M_LOCK(myLock);
		  RELEASE(pm);
		  RELEASE(rp);
		  [localException raise];
		}
	      NS_ENDHANDLER
	      M_LOCK(myLock);
	      RELEASE(pm);
	      RELEASE(rp);
	      bytes = [rData mutableBytes];
	    }
	}
    }
  else
    {
      if (state == GS_H_TRYCON)	/* Connection attempt.	*/
	{
	  int	res = 0;
	  int	len = sizeof(res);

	  if (getsockopt(desc, SOL_SOCKET, SO_ERROR, (char*)&res, &len) == 0
	    && res != 0)
	    {
	      state = GS_H_UNCON;
	      NSLog(@"connect attempt failed - %s", GSLastErrorStr(res));
	    }
	  else
	    {
	      NSData	*d = newDataWithEncodedPort([self recvPort]);

#ifdef __MINGW__
	      len = send(desc, [d bytes], [d length], 0);
#else
	      len = write(desc, [d bytes], [d length]);
#endif
	      if (len == (int)[d length])
		{
		  NSDebugMLLog(@"NSMessagePort_details",
		    @"wrote %d bytes on 0x%x in thread 0x%x",
		    len, self, GSCurrentThread());
		  state = GS_H_CONNECTED;
		}
	      else
		{
		  state = GS_H_UNCON;
		  NSLog(@"connect write attempt failed - %s",
		    GSLastErrorStr(errno));
		}
	      RELEASE(d);
	    }
	}
      else
	{
	  int		res;
	  unsigned	l;
	  const void	*b;

	  if (wData == nil)
	    {
	      if ([wMsgs count] > 0)
		{
		  NSArray	*components = [wMsgs objectAtIndex: 0];

		  wData = [components objectAtIndex: wItem++];
		  wLength = 0;
		}
	      else
		{
		  // NSLog(@"No messages to write on 0x%x.", self);
		  M_UNLOCK(myLock);
		  return;
		}
	    }
	  b = [wData bytes];
	  l = [wData length];
#ifdef __MINGW__
	  res = send(desc, b + wLength,  l - wLength, 0);
#else
	  res = write(desc, b + wLength,  l - wLength);
#endif
	  if (res < 0)
	    {
	      if (errno != EINTR && errno != EAGAIN)
		{
		  NSLog(@"write attempt failed - %s", GSLastErrorStr(errno));
		  M_UNLOCK(myLock);
		  [self invalidate];
		  return;
		}
	    }
	  else
	    {
	      NSDebugMLLog(@"NSMessagePort_details",
		@"wrote %d bytes on 0x%x in thread 0x%x",
		res, self, GSCurrentThread());
	      wLength += res;
	      if (wLength == l)
		{
		  NSArray	*components;

		  /*
		   * We have completed a data item so see what is
		   * left of the message components.
		   */
		  components = [wMsgs objectAtIndex: 0];
		  wLength = 0;
		  if ([components count] > wItem)
		    {
		      /*
		       * More to write - get next item.
		       */
		      wData = [components objectAtIndex: wItem++];
		    }
		  else
		    {
		      /*
		       * message completed - remove from list.
		       */
		      NSDebugMLLog(@"NSMessagePort_details",
			@"completed 0x%x on 0x%x in thread 0x%x",
			components, self, GSCurrentThread());
		      wData = nil;
		      wItem = 0;
		      [wMsgs removeObjectAtIndex: 0];
		    }
		}
	    }
	}
    }

  M_UNLOCK(myLock);
}

- (BOOL) sendMessage: (NSArray*)components beforeDate: (NSDate*)when
{
  NSRunLoop	*l;
  BOOL		sent = NO;

  NSAssert([components count] > 0, NSInternalInconsistencyException);
  NSDebugMLLog(@"NSMessagePort_details",
    @"Sending message 0x%x %@ on 0x%x(%d) in thread 0x%x before %@",
    components, components, self, desc, GSCurrentThread(), when);
  M_LOCK(myLock);
  [wMsgs addObject: components];

  l = [runLoopClass currentRunLoop];

  RETAIN(self);

  [l addEvent: (void*)(gsaddr)desc
	 type: ET_WDESC
      watcher: self
      forMode: NSConnectionReplyMode];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_EDESC
      watcher: self
      forMode: NSConnectionReplyMode];

  while (valid == YES
    && [wMsgs indexOfObjectIdenticalTo: components] != NSNotFound
    && [when timeIntervalSinceNow] > 0)
    {
      M_UNLOCK(myLock);
      [l runMode: NSConnectionReplyMode beforeDate: when];
      M_LOCK(myLock);
    }

  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_WDESC
	 forMode: NSConnectionReplyMode
	     all: NO];
  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_EDESC
	 forMode: NSConnectionReplyMode
	     all: NO];

  if ([wMsgs indexOfObjectIdenticalTo: components] == NSNotFound)
    {
      sent = YES;
    }
  M_UNLOCK(myLock);
  RELEASE(self);
  NSDebugMLLog(@"NSMessagePort_details",
    @"Message send 0x%x on 0x%x in thread 0x%x status %d",
    components, self, GSCurrentThread(), sent);
  return sent;
}

- (NSMessagePort*) sendPort
{
  if (sendPort == nil)
    return nil;
  else if (caller == YES)
    return GS_GC_UNHIDE(sendPort);	// We called, so port is not retained.
  else
    return sendPort;			// Retained port.
}

- (void) setState: (GSHandleState)s
{
  state = s;
}

- (GSHandleState) state
{
  return state;
}

- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode
{
  return nil;
}

@end



@interface NSMessagePort (RunLoop) <RunLoopEvents>
- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode;
- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode;
@end


@implementation	NSMessagePort

static NSRecursiveLock	*messagePortLock = nil;

/*
Maps NSData objects with the socket name to NSMessagePort objects.
*/
static NSMapTable	*messagePortMap = 0;
static Class		messagePortClass;


static void clean_up_sockets(void)
{
  NSMessagePort *port;
  NSData *name;
  NSMapEnumerator mEnum;
  BOOL	unknownThread = GSRegisterCurrentThread();
  CREATE_AUTORELEASE_POOL(arp);

  mEnum = NSEnumerateMapTable(messagePortMap);
  while (NSNextMapEnumeratorPair(&mEnum, (void *)&name, (void *)&port))
    {
      if ([port _listener] != -1)
	unlink([name bytes]);
    }
  NSEndMapTableEnumeration(&mEnum);
  DESTROY(arp);
  if (unknownThread == YES)
    {
      GSUnregisterCurrentThread();
    }
}


#if NEED_WORD_ALIGNMENT
static unsigned	wordAlign;
#endif

+ (void) initialize
{
  if (self == [NSMessagePort class])
    {
#if NEED_WORD_ALIGNMENT
      wordAlign = objc_alignof_type(@encode(gsu32));
#endif
      messagePortClass = self;
      messagePortMap = NSCreateMapTable(NSNonRetainedObjectMapKeyCallBacks,
	NSNonOwnedPointerMapValueCallBacks, 0);

      messagePortLock = [GSLazyRecursiveLock new];
      atexit(clean_up_sockets);
    }
}

+ (id) new
{
static int unique_index = 0;
  NSString	*path;
  NSNumber	*p = [NSNumber numberWithInt: 0700];
  NSDictionary	*attr;

  attr = [NSDictionary dictionaryWithObject: p
				     forKey: NSFilePosixPermissions];

  path = NSTemporaryDirectory();

  path = [path stringByAppendingPathComponent: @"NSMessagePort"];
  [[NSFileManager defaultManager] createDirectoryAtPath: path
				  attributes: attr];

  path = [path stringByAppendingPathComponent: @"ports"];
  [[NSFileManager defaultManager] createDirectoryAtPath: path
				  attributes: attr];

  M_LOCK(messagePortLock);
  path = [path stringByAppendingPathComponent:
   [NSString stringWithFormat: @"%i.%i",
	[[NSProcessInfo processInfo] processIdentifier], unique_index++]];
  M_UNLOCK(messagePortLock);

  return RETAIN([self _portWithName: [path fileSystemRepresentation]
			   listener: YES]);
}

/*
 * This is the preferred initialisation method for NSMessagePort
 *
 * 'socketName' is the name of the socket in the port directory
 */
+ (NSMessagePort*) _portWithName: (const unsigned char *)socketName
		     listener: (BOOL)shouldListen
{
  unsigned		i;
  NSMessagePort		*port = nil;
  NSData *theName = [[NSData alloc] initWithBytes: socketName  length: strlen(socketName)+1];

  M_LOCK(messagePortLock);

  /*
   * First try to find a pre-existing port.
   */
  port = (NSMessagePort*)NSMapGet(messagePortMap, theName);

  if (port == nil)
    {
      port = (NSMessagePort*)NSAllocateObject(self, 0, NSDefaultMallocZone());
      port->name = theName;
      port->listener = -1;
      port->handles = NSCreateMapTable(NSIntMapKeyCallBacks,
	NSObjectMapValueCallBacks, 0);
      port->myLock = [GSLazyRecursiveLock new];
      port->_is_valid = YES;

      if (shouldListen == YES)
	{
	  int	desc;
	  struct sockaddr_un	sockaddr;

	  /*
	   * Creating a new port on the local host - so we must create a
	   * listener socket to accept incoming connections.
	   */
	  memset(&sockaddr, '\0', sizeof(sockaddr));
	  sockaddr.sun_family = AF_LOCAL;
	  strncpy(sockaddr.sun_path, socketName, sizeof(sockaddr.sun_path));

	  /*
           * Need size of buffer for getsockbyname() later.
	   */
	  i = sizeof(sockaddr);

	  if ((desc = socket(PF_LOCAL, SOCK_STREAM, PF_UNSPEC)) < 0)
	    {
	      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
	      DESTROY(port);
	    }
	  else if (bind(desc, (struct sockaddr *)&sockaddr,
	    sizeof(sockaddr)) < 0)
	    {
	      NSLog(@"unable to bind to %s - %s",
		sockaddr.sun_path, GSLastErrorStr(errno));
	      (void) close(desc);
              DESTROY(port);
	    }
	  else if (listen(desc, 5) < 0)
	    {
	      NSLog(@"unable to listen on port - %s", GSLastErrorStr(errno));
	      (void) close(desc);
	      DESTROY(port);
	    }
	  else if (getsockname(desc, (struct sockaddr*)&sockaddr, &i) < 0)
	    {
	      NSLog(@"unable to get socket name - %s", GSLastErrorStr(errno));
	      (void) close(desc);
	      DESTROY(port);
	    }
	  else
	    {
	      /*
	       * Set up the listening descriptor and the actual message port
	       * number (which will have been set to a real port number when
	       * we did the 'bind' call.
	       */
	      port->listener = desc;
	      /*
	       * Make sure we have the map table for this port.
	       */
	      NSMapInsert(messagePortMap, (void*)theName, (void*)port);
	      NSDebugMLLog(@"NSMessagePort", @"Created listening port: %@", port);
	    }
	}
      else
	{
	  /*
	   * Make sure we have the map table for this port.
	   */
	  NSMapInsert(messagePortMap, (void*)theName, (void*)port);
	  NSDebugMLLog(@"NSMessagePort", @"Created speaking port: %@", port);
	}
    }
  else
    {
      RELEASE(theName);
      RETAIN(port);
      NSDebugMLLog(@"NSMessagePort", @"Using pre-existing port: %@", port);
    }
  IF_NO_GC(AUTORELEASE(port));

  M_UNLOCK(messagePortLock);
  return port;
}

- (void) addHandle: (GSMessageHandle*)handle forSend: (BOOL)send
{
  M_LOCK(myLock);
  if (send == YES)
    {
      if (handle->caller == YES)
	handle->sendPort = GS_GC_HIDE(self);
      else
	ASSIGN(handle->sendPort, self);
    }
  else
    {
      handle->recvPort = GS_GC_HIDE(self);
    }
  NSMapInsert(handles, (void*)(gsaddr)[handle descriptor], (void*)handle);
  M_UNLOCK(myLock);
}

- (id) copyWithZone: (NSZone*)zone
{
  return RETAIN(self);
}

- (void) dealloc
{
  [self gcFinalize];
  DESTROY(name);
  [super dealloc];
}

- (NSString*) description
{
  NSString	*desc;

  desc = [NSString stringWithFormat: @"<NSMessagePort %p with name %s>",
	   self, [name bytes]];
  return desc;
}

- (void) gcFinalize
{
  NSDebugMLLog(@"NSMessagePort", @"NSMessagePort 0x%x finalized", self);
  [self invalidate];
}

/*
 * This is a callback method used by the NSRunLoop class to determine which
 * descriptors to watch for the port.
 */
- (void) getFds: (int*)fds count: (int*)count
{
  NSMapEnumerator	me;
  int			sock;
  GSMessageHandle		*handle;
  id			recvSelf;

  M_LOCK(myLock);

  /*
   * Make sure there is enough room in the provided array.
   */
  NSAssert(*count > (int)NSCountMapTable(handles),
    NSInternalInconsistencyException);

  /*
   * Put in our listening socket.
   */
  *count = 0;
  if (listener >= 0)
    {
      fds[(*count)++] = listener;
    }

  /*
   * Enumerate all our socket handles, and put them in as long as they
   * are to be used for receiving.
   */
  recvSelf = GS_GC_HIDE(self);
  me = NSEnumerateMapTable(handles);
  while (NSNextMapEnumeratorPair(&me, (void*)&sock, (void*)&handle))
    {
      if (handle->recvPort == recvSelf)
	{
	  fds[(*count)++] = sock;
	}
    }
  NSEndMapTableEnumeration(&me);
  M_UNLOCK(myLock);
}

- (GSMessageHandle*) handleForPort: (NSMessagePort*)recvPort beforeDate: (NSDate*)when
{
  NSMapEnumerator	me;
  int			sock;
  int			opt = 1;
  GSMessageHandle		*handle = nil;

  M_LOCK(myLock);
  /*
   * Enumerate all our socket handles, and look for one with port.
   */
  me = NSEnumerateMapTable(handles);
  while (NSNextMapEnumeratorPair(&me, (void*)&sock, (void*)&handle))
    {
      if ([handle recvPort] == recvPort)
	{
	  M_UNLOCK(myLock);
	  NSEndMapTableEnumeration(&me);
	  return handle;
	}
    }
  NSEndMapTableEnumeration(&me);

  /*
   * Not found ... create a new handle.
   */
  handle = nil;
  if ((sock = socket(PF_LOCAL, SOCK_STREAM, PF_UNSPEC)) < 0)
    {
      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
    }
#ifndef	BROKEN_SO_REUSEADDR
  /*
   * Under decent systems, SO_REUSEADDR means that the port can be reused
   * immediately that this process exits.  Under some it means
   * that multiple processes can serve the same port simultaneously.
   * We don't want that broken behavior!
   */
  else if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&opt,
    sizeof(opt)) < 0)
    {
      (void)close(sock);
      NSLog(@"unable to set reuse on socket - %s", GSLastErrorStr(errno));
    }
#endif
  else if ((handle = [GSMessageHandle handleWithDescriptor: sock]) == nil)
    {
      (void)close(sock);
      NSLog(@"unable to create GSMessageHandle - %s", GSLastErrorStr(errno));
    }
  else
    {
      [recvPort addHandle: handle forSend: NO];
    }
  M_UNLOCK(myLock);
  /*
   * If we succeeded in creating a new handle - connect to remote host.
   */
  if (handle != nil)
    {
      if ([handle connectToPort: self beforeDate: when] == NO)
	{
	  [handle invalidate];
	  handle = nil;
	}
    }
  return handle;
}

- (void) handlePortMessage: (NSPortMessage*)m
{
  id	d = [self delegate];

  if (d == nil)
    {
      NSDebugMLLog(@"NSMessagePort", @"No delegate to handle incoming message", 0);
      return;
    }
  if ([d respondsToSelector: @selector(handlePortMessage:)] == NO)
    {
      NSDebugMLLog(@"NSMessagePort", @"delegate doesn't handle messages", 0);
      return;
    }
  [d handlePortMessage: m];
}

- (unsigned) hash
{
  return [name hash];
}

- (id) init
{
  RELEASE(self);
  self = [messagePortClass new];
  return self;
}

- (void) invalidate
{
  if ([self isValid] == YES)
    {
      M_LOCK(myLock);

      if ([self isValid] == YES)
	{
	  NSArray	*handleArray;
	  unsigned	i;

	  M_LOCK(messagePortLock);
	  if (listener >= 0)
	    {
	      (void) close(listener);
	      unlink([name bytes]);
	      listener = -1;
	    }
	  NSMapRemove(messagePortMap, (void*)name);
	  M_UNLOCK(messagePortLock);

	  if (handles != 0)
	    {
	      handleArray = NSAllMapTableValues(handles);
	      i = [handleArray count];
	      while (i-- > 0)
		{
		  GSMessageHandle	*handle = [handleArray objectAtIndex: i];

		  [handle invalidate];
		}
	      /*
	       * We permit mutual recursive invalidation, so the handles map
	       * may already have been destroyed.
	       */
	      if (handles != 0)
		{
		  NSFreeMapTable(handles);
		  handles = 0;
		}
	    }
	  [[NSMessagePortNameServer sharedInstance] removePort: self];
	  [super invalidate];
	}
      M_UNLOCK(myLock);
    }
}

- (BOOL) isEqual: (id)anObject
{
  if (anObject == self)
    {
      return YES;
    }
  if ([anObject class] == [self class])
    {
      NSMessagePort	*o = (NSMessagePort*)anObject;

      return [o->name isEqual: name];
    }
  return NO;
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode
{
  int		desc = (int)(gsaddr)extra;
  GSMessageHandle	*handle;

  if (desc == listener)
    {
      struct sockaddr_un	sockAddr;
      int			size = sizeof(sockAddr);

      desc = accept(listener, (struct sockaddr*)&sockAddr, &size);
      if (desc < 0)
        {
	  NSDebugMLLog(@"NSMessagePort", @"accept failed - handled in other thread?");
        }
      else
	{
	  /*
	   * Create a handle for the socket and set it up so we are its
	   * receiving port, and it's waiting to get the port name from
	   * the other end.
	   */
	  handle = [GSMessageHandle handleWithDescriptor: desc];
	  memcpy(&handle->sockAddr, &sockAddr, sizeof(sockAddr));

	  [handle setState: GS_H_ACCEPT];
	  [self addHandle: handle forSend: NO];
	}
    }
  else
    {
      M_LOCK(myLock);
      handle = (GSMessageHandle*)NSMapGet(handles, (void*)(gsaddr)desc);
      IF_NO_GC(AUTORELEASE(RETAIN(handle)));
      M_UNLOCK(myLock);
      if (handle == nil)
	{
	  const char	*t;

	  if (type == ET_RDESC) t = "rdesc";
	  else if (type == ET_WDESC) t = "wdesc";
	  else if (type == ET_EDESC) t = "edesc";
	  else if (type == ET_RPORT) t = "rport";
	  else t = "unknown";
	  NSLog(@"No handle for event %s on descriptor %d", t, desc);
	  [[runLoopClass currentRunLoop] removeEvent: extra
						type: type
					     forMode: mode
						 all: YES];
	}
      else
	{
	  [handle receivedEvent: data type: type extra: extra forMode: mode];
	}
    }
}

- (void) removeHandle: (GSMessageHandle*)handle
{
  M_LOCK(myLock);
  if ([handle sendPort] == self)
    {
      if (handle->caller != YES)
	{
	  /*
	   * This is a handle for a send port, and the handle was not formed
	   * by calling the remote process, so this port object must have
	   * been created to deal with an incoming connection and will have
	   * been retained - we must therefore release this port since the
	   * handle no longer uses it.
	   */
	  AUTORELEASE(self);
	}
      handle->sendPort = nil;
    }
  if ([handle recvPort] == self)
    {
      handle->recvPort = nil;
    }
  NSMapRemove(handles, (void*)(gsaddr)[handle descriptor]);
  if (listener < 0 && NSCountMapTable(handles) == 0)
    {
      [self invalidate];
    }
  M_UNLOCK(myLock);
}

/*
 * This returns the amount of space that a port coder should reserve at the
 * start of its encoded data so that the NSMessagePort can insert header info
 * into the data.
 * The idea is that a message consisting of a single data item with space at
 * the start can be written directly without having to copy data to another
 * buffer etc.
 */
- (unsigned int) reservedSpaceLength
{
  return sizeof(GSPortItemHeader) + sizeof(GSPortMsgHeader);
}

- (BOOL) sendBeforeDate: (NSDate*)when
		  msgid: (int)msgId
             components: (NSMutableArray*)components
                   from: (NSPort*)receivingPort
               reserved: (unsigned)length
{
  BOOL		sent = NO;
  GSMessageHandle	*h;
  unsigned	rl;

  if ([self isValid] == NO)
    {
      return NO;
    }
  if ([components count] == 0)
    {
      NSLog(@"empty components sent");
      return NO;
    }
  /*
   * If the reserved length in the first data object is wrong - we have to
   * fail, unless it's zero, in which case we can insert a data object for
   * the header.
   */
  rl = [self reservedSpaceLength];
  if (length != 0 && length != rl)
    {
      NSLog(@"bad reserved length - %u", length);
      return NO;
    }
  if ([receivingPort isKindOfClass: messagePortClass] == NO)
    {
      NSLog(@"woah there - receiving port is not the correct type");
      return NO;
    }

  h = [self handleForPort: (NSMessagePort*)receivingPort beforeDate: when];
  if (h != nil)
    {
      NSMutableData	*header;
      unsigned		hLength;
      unsigned		l;
      GSPortItemHeader	*pih;
      GSPortMsgHeader	*pmh;
      unsigned		c = [components count];
      unsigned		i;
      BOOL		pack = YES;

      /*
       * Ok - ensure we have space to insert header info.
       */
      if (length == 0 && rl != 0)
	{
	  header = [[mutableDataClass alloc] initWithCapacity: NETBLOCK];

	  [header setLength: rl];
	  [components insertObject: header atIndex: 0];
	  RELEASE(header);
	} 

      header = [components objectAtIndex: 0];
      /*
       * The Item header contains the item type and the length of the
       * data in the item (excluding the item header itself).
       */
      hLength = [header length];
      l = hLength - sizeof(GSPortItemHeader);
      pih = (GSPortItemHeader*)[header mutableBytes];
      pih->type = GSSwapHostI32ToBig(GSP_HEAD);
      pih->length = GSSwapHostI32ToBig(l);

      /*
       * The message header contains the message Id and the original count
       * of components in the message (excluding any extra component added
       * simply to hold the header).
       */
      pmh = (GSPortMsgHeader*)&pih[1];
      pmh->mId = GSSwapHostI32ToBig(msgId);
      pmh->nItems = GSSwapHostI32ToBig(c);

      /*
       * Now insert item header information as required.
       * Pack as many items into the initial data object as possible, up to
       * a maximum of NETBLOCK bytes.  This is to try to get a single,
       * efficient write operation if possible.
       */
      for (i = 1; i < c; i++)
	{
	  id	o = [components objectAtIndex: i];

	  if ([o isKindOfClass: [NSData class]])
	    {
	      GSPortItemHeader	*pih;
	      unsigned		h = sizeof(GSPortItemHeader);
	      unsigned		l = [o length];
	      void		*b;

	      if (pack == YES && hLength + l + h <= NETBLOCK)
		{
		  [header setLength: hLength + l + h];
		  b = [header mutableBytes];
		  b += hLength;
#if NEED_WORD_ALIGNMENT
		  /*
		   * When packing data, an item may not be aligned on a
		   * word boundary, so we work with an aligned buffer
		   * and use memcmpy()
		   */
		  if ((hLength % wordAlign) != 0)
		    {
		      GSPortItemHeader	itemHeader;

		      pih = (GSPortItemHeader*)&itemHeader;
		      pih->type = GSSwapHostI32ToBig(GSP_DATA);
		      pih->length = GSSwapHostI32ToBig(l);
		      memcpy(b, (void*)pih, h);
		    }
		  else
		    {
		      pih = (GSPortItemHeader*)b;
		      pih->type = GSSwapHostI32ToBig(GSP_DATA);
		      pih->length = GSSwapHostI32ToBig(l);
		    }
#else
		  pih = (GSPortItemHeader*)b;
		  pih->type = GSSwapHostI32ToBig(GSP_DATA);
		  pih->length = GSSwapHostI32ToBig(l);
#endif
		  memcpy(b+h, [o bytes], l);
		  [components removeObjectAtIndex: i--];
		  c--;
		  hLength += l + h;
		}
	      else
		{
		  NSMutableData	*d;

		  pack = NO;
		  d = [[NSMutableData alloc] initWithLength: l + h];
		  b = [d mutableBytes];
		  pih = (GSPortItemHeader*)b;
		  memcpy(b+h, [o bytes], l);
		  pih->type = GSSwapHostI32ToBig(GSP_DATA);
		  pih->length = GSSwapHostI32ToBig(l);
		  [components replaceObjectAtIndex: i
					withObject: d];
		  RELEASE(d);
		}
	    }
	  else if ([o isKindOfClass: messagePortClass])
	    {
	      NSData	*d = newDataWithEncodedPort(o);
	      unsigned	dLength = [d length];

	      if (pack == YES && hLength + dLength <= NETBLOCK)
		{
		  void	*b;

		  [header setLength: hLength + dLength];
		  b = [header mutableBytes];
		  b += hLength;
		  hLength += dLength;
		  memcpy(b, [d bytes], dLength);
		  [components removeObjectAtIndex: i--];
		  c--;
		}
	      else
		{
		  pack = NO;
		  [components replaceObjectAtIndex: i withObject: d];
		}
	      RELEASE(d);
	    }
	}

      /*
       * Now send the message.
       */
      sent = [h sendMessage: components beforeDate: when];
    }
  return sent;
}

- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode
{
  return nil;
}


-(const unsigned char *) _name
{
  return [name bytes];
}

-(int) _listener
{
  return listener;
}

@end

