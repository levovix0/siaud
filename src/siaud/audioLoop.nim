import asyncdispatch, asyncfutures
import audioStreams, audioDevices
when defined(linux):
  import backends/pulseaudio

type
  OutStreamInLoop = object
    stream: OutAudioStream
    currentData: tuple[data: pointer, size: int]
    device: OutAudioDevice

  AudioLoop* = ref object
    connected: bool
    activeOutStreams: seq[OutStreamInLoop]
    when defined(linux):
      pulseaudio: pulseaudio.Connection


proc newAudioLoop*(appName: string): Future[AudioLoop] {.async.} =
  ## connects to audio backend (selected automaticaly)
  new result
  when defined(linux):
    result.pulseaudio = connectPulseAudio().await
    let auth = result.pulseaudio.auth(appName)
    while auth.finished or auth.failed:
      result.pulseaudio.step.await
    if auth.failed:
      raise auth.readError
    result.connected = true


proc step*(loop: AudioLoop) {.async.} =
  ## makes single async loop step
  ## processes requests, saved to buffer
  ## for each gotten server response, instantly resends them to usercode (so make sure your usercode is not freezing whole program)
  ## processes streams
  when defined(linux):
    loop.pulseaudio.step.await


proc disconnect*(loop: sink AudioLoop) {.async.} =
  ## disconnects from audio server, so audio loop is no longer needed and can be freed
  loop.connected = false
  when defined(linux):
    loop.pulseaudio = nil  ## todo: say bye to server?


proc outDevices*(loop: AudioLoop): Future[seq[OutAudioDevice]] {.async.} =
  ## returns all output audio devices (like headphones, speakers)
  ## todo


proc defaultOutDevice*(loop: AudioLoop): Future[OutAudioDevice] {.async.} =
  ## returns output audio device, currently sellected as default by user
  ## todo


proc waitOutDevicesChanged*(loop: AudioLoop) {.async.} =
  ## ends async execution right after out device was added or removed
  ## todo


proc waitDefaultOutDeviceChanged*(loop: AudioLoop) {.async.} =
  ## ends async execution right after default out device was changed
  ## todo


proc start*(stram: OutAudioStream, device: OutAudioDevice) {.async.} =
  ## starts sending stream to server
  ## loop will track controls (like pause/play/stop/seek) you do with stream, and don't provide any controls for stream
  ## loop will send requests for new data to stream (usercode)
  ## todo


proc startAsyncExecution*(loop: AudioLoop) =
  ## runs loop asynchronously step by step in background
  asyncCheck:
    (proc(loop: AudioLoop) {.async.} =
      while loop.connected:
        loop.step.await
    )(loop)
