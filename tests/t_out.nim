import unittest, asyncdispatch
import siaud

test "out wav":
  let loop = newAudioLoop("siaud out vaw test").waitFor
  startAsyncExecution loop
  let stream = newWavFileOutStream("sounds/a.wav")
  loop.start(stream, al.defaultOutDevice.waitFor)
  while not stream.atEnd:
    poll()
