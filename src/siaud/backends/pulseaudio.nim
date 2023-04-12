import os, asyncnet, nativesockets, posix, sequtils, sets, asyncdispatch, tables, options, endians, math

{.experimental: "overloadableEnums".}

{.passl: "-lxcb".}

type
  Tag {.size: byte.sizeof.} = enum
    tNull = '\0'
    tFalse = '0'
    tTrue = '1'
    tUint8 = 'B'
    tUint32 = 'L'
    tStringNull = 'N'
    tPropList = 'P'
    tUspec = 'U'
    tVolume = 'V'
    tSampleSpec = 'a'
    tFormatInfo = 'f'
    tChanelMap = 'm'
    tString = 't'
    tCvolume = 'v'
    tArbitrary = 'x'

  Command {.size: uint32.sizeof.} = enum
    error = 0
    reply = 2
    # client -> server
    createOutStream = 3
    auth = 8
    setClientName = 9
    getServerInfo = 20
    getSinkInfoList = 22
    setDefaultSink = 44
    # server -> client
    request = 61
    subscribeEvent = 66
  
  ErrorCode {.size: uint32.sizeof.} = enum
    ok = 0
    accessDenied = "access denied"
    unknownComand = "unknown comand"
    invalidArgument = "invalid argument"
    entityExists = "already exists"
    noSuchEntity = "no such entity"
    connectionRefused = "connection refused"
    protocolError = "protocol error"
    timeout
    noAuthKey = "no auth key"
    internalError = "internal error"
    connectionTerminated = "connection terminated"
    entityKilled = "entity killed"
    invalidServer = "invalid server"
    moduleInitFailed = "module init failed"
    badState = "bas state"
    noData = "no data"
    incompatibleProtocolVersion = "incompatible protocol version"
    tooLarge = "too large"
    notSupported = "not supported"
    unkonown
    noSuchExtention = "no such extention"
    obsoleteFunctionality = "obsolete functionalty"
    missingImplementation = "missing implementation"
    clientForked = "client forked"
    ioError = "input/output error"
    busy = "device or resource busy"
    
  
  Response* = object
    case isError: bool
    of true:
      error: tuple[command: Command, errorCode: ErrorCode]
    of false:
      response: string

  Connection* = ref object
    serverVersion: uint32
    clientIndex: uint32
    
    socket: AsyncSocket

    lastRequest: uint32
    requestsSent: HashSet[uint32]
    requestsResponses: Table[uint32, Response]
    lastSyncid: uint32

  PulseAudioError* = object of CatchableError
  

  Arbitary = distinct string

  WhileSeq[T] = distinct seq[T]

  Since*[I: static int; T] = distinct T


  SampleFormat {.size: byte.sizeof.} = enum
    invalid = -1
    u8 = 0
    alaw8
    mulaw8
    i16_little_endian
    i16_big_endian
    f32_little_endian
      ## range -1..1
    f32_big_endian
      ## range -1..1
    i32_little_endian
    i32_big_endian
    i24_little_endian
    i24_big_endian
    i24_32_little_endian
    i24_32_big_endian

  SampleSpec* = object
    format*: SampleFormat
    chans*: byte
    rate*: uint32
  
  ChanMap* = object
    data*: seq[byte]
  
  Cvolume* = object
    data*: seq[uint32]
  
  FormatInfo* = object
    encoding*: byte
    props*: Table[string, string]
  
  Formats* = object
    data*: seq[FormatInfo]


  BufferInfo* = object
    maxLen*: uint32
    targetLen*: Option[uint32]
      ## outStream only
      ## if none, server default
    startMinLen*: Option[uint32]
      ## outStream only
      ## minimum length, after that server will start playing audio
      ## if none, same as targetLen
    minLen*: Option[uint32]
      ## outStream only
      ## if none, server default
    fragSize*: Option[uint32]
      ## inStream only
      ## if none, server default


  ServerInfo* = object
    packName*, packVer*: string
    user*, host*: string
    sampleSpec*: SampleSpec
    defaultSink*, defaultSource*: string
    cookie*: uint32
    chanMap*: ChanMap


  Sink* = object
    ## like OutStream
    index*: uint32
    name*, desc*: string
    sampleSpec*: SampleSpec
    chanMap*: ChanMap
    moduleIndex*: uint32
    cvolume*: Cvolume
    muted*: bool
    monitorSourceIdx*: uint32
    monitorSourceName*: string
    latency*: uint64
    dirver*: string
    flags*: uint32
    props*: Since[13, Table[string, string]]
    reqLatency*: Since[13, uint64]
    baseVolume*: Since[15, float32]
    sinkState*: Since[15, uint32]
    volumeStepsNum*: Since[15, uint32]
    cardIndex*: Since[15, uint32]
    ports*: Since[16, seq[tuple[name, desc: string; priority: uint32, available: Since[24, uint32]]]]
    activePortName*: Since[16, string]
    formats: Since[21, Formats]
  
  OutStream* = object
    chan*: uint32
    index*: uint32
    missing*: uint32
    maxLen*, targetLen*, startMinLen*, minLen*: Since[9, uint32]
    sampleSpec*: Since[12, SampleSpec]
    chanMap*: Since[12, ChanMap]
    peerIndex*: Since[12, uint32]
    peerName*: Since[12, string]
    sinkSuspendedState*: Since[12, bool]
    latency*: Since[13, uint64]
    formats*: Since[21, FormatInfo]


const version = 32'u32
# const version = 13'u32


template getVersion*[I: static int; T](since: type Since[I, T]): static int = I
template getType*[I: static int; T](since: type Since[I, T]): type = T

proc `[]`*[I: static int; T](since: Since[I, T]): T = (T)(since)
proc `[]`*[I: static int; T](since: var Since[I, T]): var T = (T)(since)
proc since*[T](x: T, v: static int): Since[v, T] = Since[v, T](x)

proc `$`*[I: static int; T](since: Since[I, T]): string =
  $since[]


proc decode[T](res: string, i: var int, x: var T, ver: int) =
  proc expectLen(i, l: int) =
    if i + l > res.len:
      raise PulseAudioError.newException("response length is less than expected")
  
  proc expectTag(i: var int, t: Tag) {.used.} =
    i.expectLen 1
    var u: Tag
    copyMem(u.addr, res[i].unsafeaddr, 1)
    if u != t:
      raise PulseAudioError.newException("unexpected tag: " & $u & ", expected: " & $t)
    inc i, 1
  
  proc readUint32(i: var int): uint32 {.used.} =
    i.expectLen 4
    when cpuEndian == littleEndian:
      swapEndian32(result.addr, res[i].unsafeaddr)
    else:
      copyMem(result.addr, res[i].unsafeaddr, 4)
    inc i, 4

  proc readFloat32(i: var int): float32 {.used.} =
    i.expectLen 4
    when cpuEndian == littleEndian:
      swapEndian32(result.addr, res[i].unsafeaddr)
    else:
      copyMem(result.addr, res[i].unsafeaddr, 4)
    inc i, 4

  proc readUint64(i: var int): uint64 {.used.} =
    i.expectLen 8
    when cpuEndian == littleEndian:
      swapEndian64(result.addr, res[i].unsafeaddr)
    else:
      copyMem(result.addr, res[i].unsafeaddr, 8)
    inc i, 8

  when T is uint32|enum:
    i.expectTag tUint32
    x = cast[T](i.readUint32)

  elif T is uint64:
    i.expectTag tUspec
    x = i.readUint64
  
  elif T is byte:
    i.expectTag tUint8
    i.expectLen 1
    x = res[i].byte
    inc i
  
  elif T is float32:
    i.expectTag tVolume
    x = i.readFloat32
    

  elif T is Arbitary:
    i.expectTag tArbitrary
    i.expectLen 4
    let l = i.readUint32
    if l > 1:
      i.expectLen l.int
      x = Arbitary(newString(l-1))
      copyMem(x.string[0].addr, res[i].unsafeaddr, l.int-1)
    inc i, l.int
  
  elif T is string:
    i.expectLen 1
    if res[i] == tStringNull.char:
      return
    i.expectTag tString
    while true:
      i.expectLen 1
      defer: inc i
      if res[i] == '\0':
        break
      x.add res[i]
  
  elif T is bool:
    i.expectLen 1
    var u: Tag
    copyMem(u.addr, res[i].unsafeaddr, 1)
    case u
    of tTrue: x = true
    of tFalse: x = false
    else: raise PulseAudioError.newException("expected tTrue or tFalse, got " & $u)
    inc i

  elif T is seq:
    i.expectLen 4
    var l: uint32
    res.decode(i, l, ver)
    x.setLen l
    for j in 0..<l:
      res.decode(i, x[j], ver)
  
  elif T is Table[string, string]:
    i.expectTag tPropList
    while true:
      i.expectLen 1
      if res[i] == tStringNull.char:
        inc i, 1
        break
      var
        k: string
        l: uint32
        v: Arbitary
      res.decode(i, k, ver)
      res.decode(i, l, ver)
      res.decode(i, v, ver)
      x[k] = v.string

  elif T is WhileSeq:
    type Item = T.T
    while i < res.len:
      var item: Item
      res.decode(i, item, ver)
      (seq[Item])(x).add item
  
  elif T is Since:
    let version = T.getVersion
    if ver >= version:
      res.decode(i, x[], ver)

  elif T is SampleSpec:
    i.expectTag tSampleSpec
    i.expectLen 6
    x.format = res[i].SampleFormat
    x.chans = res[i+1].byte
    inc i, 2
    x.rate = i.readUint32
  
  elif T is ChanMap:
    i.expectTag tChanelMap
    i.expectLen 1
    let l = res[i]
    inc i
    x.data.setLen l.int
    for i, v in res.toOpenArrayByte(i, i+l.int-1):
      x.data[i] = v
    inc i, l.int

  elif T is Cvolume:
    i.expectTag tCvolume
    i.expectLen 1
    var l = res[i]
    inc i
    x.data.setLen l.int
    for j in 0..<l.int:
      x.data[j] = i.readUint32

  elif T is Formats:
    var l: byte
    res.decode(i, l, ver)
    x.data.setLen l.int
    for j in 0..<l.int:
      res.decode(i, x.data[j], ver)

  elif T is FormatInfo:
    i.expectTag tFormatInfo
    res.decode(i, x.encoding, ver)
    res.decode(i, x.props, ver)
  
  elif T is ref:
    new x
    res.decode(i, x[], ver)

  elif T is object|tuple:
    for x in x.fields:
      res.decode(i, x, ver)

  else:
    {.error: "cannot decode " & $T.}

proc decode[T](res: string, x: var T, v: int) =
  var i = 0
  decode(res, i, x, v)

proc request[T](c: Connection, command: Command, args: T, responseType: type): Future[responseType] {.async.} =
  ## todo: timeout
  while c.lastRequest in c.requestsSent:
    inc c.lastRequest
    if c.lastRequest == uint32.high: c.lastRequest = 1
  let requestId = c.lastRequest

  when responseType isnot tuple[]:
    c.requestsSent.incl requestId

  var r: seq[byte]
  proc toBytes(i: uint32): array[4, byte] =
    when cpuEndian == littleEndian:
      swapEndian32(result.addr, i.unsafeaddr)
    else:
      cast[array[4, byte]](result)
  proc toBytes(i: uint64): array[8, byte] =
    when cpuEndian == littleEndian:
      swapEndian64(result.addr, i.unsafeaddr)
    else:
      cast[array[8, byte]](result)

  r.add uint32.high.toBytes
  r.add 0'u32.toBytes
  r.add 0'u32.toBytes
  r.add 0'u32.toBytes

  proc add(x: var seq[byte], v: string) =
    if v.len == 0: return
    x.setLen x.len + v.len
    copyMem(x[^v.len].addr, v[0].unsafeaddr, v.len)

  proc encode[T](res: var seq[byte], x: T, ver: int) =
    when T is uint32|enum:
      res.add cast[byte](tUint32)
      res.add x.uint32.toBytes
    
    elif T is uint64:
      res.add cast[byte](tUspec)
      res.add x.toBytes
    
    elif T is bool:
      if x:
        res.add cast[byte](tTrue)
      else:
        res.add cast[byte](tFalse)

    elif T is Tag:
      res.add cast[byte](x)

    elif T is byte:
      res.add cast[byte](tUint8)
      res.add x

    elif T is Arbitary:
      res.add cast[byte](tArbitrary)
      res.add x.string.len.uint32.toBytes
      res.add x.string
    
    elif T is string:
      if x.len == 0:
        res.add cast[byte](tStringNull)
      else:
        assert '\0' notin x, "strings sent to pulseaudio can't contain '\0', do you forget to convert string to Arbitary?"
        res.add cast[byte](tString)
        res.add x
        res.add 0
    
    elif T is Table[string, string]:
      res.add cast[byte](tPropList)
      for k, v in x:
        res.encode(k, ver)
        let v = v & "\0"
        res.encode(v.len.uint32, ver)
        res.encode(v.Arbitary, ver)
      res.add cast[byte](tStringNull)
    
    elif T is SampleSpec:
      res.add cast[byte](tSampleSpec)
      res.add x.format.byte
      res.add x.chans
      res.add x.rate.toBytes
    
    elif T is ChanMap:
      res.add cast[byte](tChanelMap)
      assert x.data.len < 256, "too much data"
      res.add x.data.len.byte
      res.add x.data
    
    elif T is Cvolume:
      res.add cast[byte](tCvolume)
      assert x.data.len < 256, "too much data"
      res.add x.data.len.byte
      for x in x.data:
        res.add x.toBytes

    elif T is Formats:
      assert x.data.len < 256, "too much data"
      res.encode(x.data.len.byte, ver)
      for x in x.data:
        res.encode(x, ver)
    
    elif T is FormatInfo:
      res.add cast[byte](tFormatInfo)
      res.encode((x.encoding, x.props), ver)
    
    elif T is Since:
      let version = T.getVersion
      if ver >= version:
        res.encode(x[], ver)

    elif T is object|tuple:
      for x in x.fields:
        res.encode(x, ver)

    else:
      {.error: "cannot encode " & $T.}

  r.encode (command, requestId), min(version, c.serverVersion).int
  r.encode args, min(version, c.serverVersion).int
  
  r.insert (r.len - 16).uint32.toBytes
  
  c.socket.send(r[0].addr, r.len).await
  
  when responseType isnot tuple[]:
    while requestId notin c.requestsResponses:
      sleepAsync(1).await
    
    defer: c.requestsResponses.del requestId

    var res: responseType
    let rsp {.cursor.} = c.requestsResponses[requestId]
    if rsp.isError:
      raise PulseAudioError.newException(
        "server returned error: " &
        $rsp.error &
        "; for request: " &
        $(command: command, requestId: requestId, args: args, argsType: $T, responseType: $responseType)
      )
    else:
      decode(rsp.response, res, min(version, c.serverVersion).int)

    return res


proc step*(c: Connection) {.async.} =
  var head: tuple[l, chan, offsetLow, offsetHigh, flags: uint32]

  if c.socket.recvInto(head.addr, head.typeof.sizeof).await != head.typeof.sizeof:
    raise PulseAudioError.newException("server connection error")
  when cpuEndian == littleEndian:
    swapEndian32(head.l.addr, head.l.addr)
    swapEndian32(head.chan.addr, head.chan.addr)
    swapEndian32(head.offsetLow.addr, head.offsetLow.addr)
    swapEndian32(head.offsetHigh.addr, head.offsetHigh.addr)
    swapEndian32(head.flags.addr, head.flags.addr)

  let data = c.socket.recv(head.l.int).await
  var i = 0

  var head2: tuple[command: Command, requestId: uint32]
  decode(data, i, head2, min(version, c.serverVersion).int)
  
  if head2.command == subscribeEvent and head2.requestId == uint32.high:
    discard
  
  elif head2.command == error:
    var err: tuple[errorCode: ErrorCode, command: Command]
    decode(data, i, err.errorCode, min(version, c.serverVersion).int)

    if head.l >= 20:
      decode(data, i, err.command, min(version, c.serverVersion).int)
    
    if head2.requestId notin c.requestsSent:
      raise PulseAudioError.newException("server responded to non-existent request: " & $head2.requestId)
    c.requestsResponses[head2.requestId] = Response(isError: true, error: (err.command, err.errorCode))
    c.requestsSent.excl head2.requestId
  
  elif head2.command == reply:
    if head2.requestId notin c.requestsSent:
      raise PulseAudioError.newException("server responded to non-existent request: " & $head2.requestId)
    c.requestsResponses[head2.requestId] = Response(isError: false, response: data[10..^1])
    c.requestsSent.excl head2.requestId
  
  elif head2.command == request:
    ## todo

  else:
    raise PulseAudioError.newException("unknown server command: " & $head2.command)


proc connected*(c: Connection): bool = not c.socket.isClosed


proc connectPulseAudio*(server: string = ""): Future[Connection] {.async.} =
  new result, proc(x: Connection) =
    close x.socket
  
  let server {.used.} =
    if server != "": server
    else:
      getEnv("XDG_RUNTIME_DIR") / "pulse/native"  # todo: correct runtime dir getting

  result.socket = newAsyncSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM, nativesockets.IPPROTO_IP)
  result.socket.connectUnix(server).await


proc auth*(c: Connection, name, language, processBinary, processId, x11Display, user, host: string) {.async.} =
  let cookiePath =
    if (let x = getEnv("PULSE_COOKIE"); x != "" and x.fileExists): x
    elif (let x = getEnv("XDG_CONFIG_HOME") / "pulse/cookie"; x.fileExists): x
    elif (let x = getHomeDir() / ".config/pulse/cookie"; x.fileExists): x
    elif (let x = getHomeDir() / ".pulse-cookie"; x.fileExists): x
    else: raise PulseAudioError.newException("No pulseaudio cookie found")
  
  let cookie = cookiePath.readFile
  if cookie.len != 256: raise PulseAudioError.newException("Wrong cookie length")

  c.serverVersion = c.request(auth, (version, cookie.Arbitary), uint32).await

  c.clientIndex = c.request(
    setClientName, {
      "application.name":           name,
      "application.language":       language,
      "application.process.binary": processBinary,
      "application.process.id":     processId,
      "window.x11.display":         x11Display,
      "application.process.user":   user,
      "application.process.host":   host,
    }.toTable,
    uint32
  ).await

proc auth*(c: Connection, name: string) {.async.} =
  c.auth(name, "en_US.UTF-8", getAppFilename(), $getCurrentProcessId(), getEnv("DISPLAY"), $geteuid().getpwuid.pw_name, getHostname()).await


proc sinks*(c: Connection): Future[seq[Sink]] {.async.} =
  return seq[Sink] c.request(getSinkInfoList, (), WhileSeq[Sink]).await

proc `defaultSink=`*(c: Connection, name: string) {.async.} =
  discard c.request(setDefaultSink, name, tuple[]).await

proc serverInfo*(c: Connection): Future[ServerInfo] {.async.} =
  return c.request(getServerInfo, (), ServerInfo).await


proc toCvolume*(volume: seq[float], max: Cvolume): Cvolume =
  for i, c in max.data:
    result.data.add uint32 round(volume[i] * c.float)

proc minimalHeardVolume*(s: Sink): seq[float] =
  for c in s.cvolume.data:
    result.add 1 / c.float


proc createOutStream*(
  c: Connection, sink: Sink,
  bufferInfo: BufferInfo,
  sampleSpec: SampleSpec,
  chanMap: ChanMap,
  volume: seq[float],
  paused: bool,
): Future[OutStream] {.async.} =
  return c.request(
    createOutStream,
    (
      sampleSpec,
      chanMap,
      # sink.index,
      uint32.high,
      "",  # sink name
      # sink.name,
      bufferInfo.maxLen,
      paused,

      bufferInfo.targetLen.get(uint32.high),
      bufferInfo.startMinLen.get(uint32.high),
      bufferInfo.minLen.get(uint32.high),
      (let sid = c.lastSyncid; inc c.lastSyncid; sid),
      volume.toCvolume(sink.cvolume),

      false.since(12),  # no remap
      false.since(12),  # no remix
      true.since(12),  # fix format
      true.since(12),  # fix rate
      true.since(12),  # fix chans
      false.since(12),  # no move
      false.since(12),  # variable rate

      false.since(13),  # muted
      true.since(13),  # adjust latency
      {
        "name": "siaud",
      }.toTable.since(13),

      false.since(14),  # volume set
      false.since(14),  # early requests

      false.since(15),  # muted set
      false.since(15),  # don't inhibit auto suspend
      false.since(15),  # fail on suspend
      
      false.since(17),  # relative volume
      
      false.since(18),  # passthrough
      
      sink.formats.since(21)
    ),
    OutStream
  ).await


when isMainModule:
  let c = connectPulseAudio().waitFor
  asyncCheck:
    (proc(c: Connection) {.async.} =
      while c.connected:
        c.step.await
    )(c)
  c.auth("siaud-pulseaudio-internal-example").waitFor
  echo c.createOutStream(
    c.sinks.waitFor[0],
    BufferInfo(maxLen: 4194304, targetLen: some uint32 35288, startMinLen: some uint32 0, minLen: some uint32 0),
    SampleSpec(format: f32_little_endian, chans: 2, rate: 48000),
    ChanMap(data: @[1.byte, 2]),
    @[0.5, 0.5],
    false,
  ).waitFor
  # echo c.serverInfo.waitFor
  while true: asyncdispatch.poll()
