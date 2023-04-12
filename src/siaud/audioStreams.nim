import asyncdispatch

{.experimental: "overloadableEnums".}

type
  OutAudioStreamSignal* = enum
    stop
      ## after stop signal, after loop recieves it, loop will delete stream to server and delete ref to this stream
    pause
    play

  OutAudioStream* = ref object of RootObj
    signals*: set[OutAudioStreamSignal]
      ## signals to control loop
      ## loop will set signals to 0 after it recieves them
  

  InAudioStreamSignal* = enum
    stop
  
  InAudioStream* = ref object of RootObj
    signals*: set[InAudioStreamSignal]


method nextData*(stream: OutAudioStream): Future[tuple[data: pointer, size: int]] {.async, base.} =
  ## get next data from stream
  ## assumes that previous data now are unused and can be freed
  return (nil, 0)


method atEnd*(stream: OutAudioStream): bool {.base.} = true
