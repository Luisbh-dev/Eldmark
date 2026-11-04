class_name ToneFixture
extends RefCounted
## Synthetic sounds for the audio tests: since there are no real sounds yet
## ([code]assets/audio/[/code] is empty), a short hand-generated tone stands in for a sound.


## A sine tone of [param frequency] Hz and [param seconds] s, mono, 16-bit at 22050 Hz.
static func make_tone(frequency: float = 440.0, seconds: float = 0.5) -> AudioStreamWAV:
	var mix_rate: int = 22050
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = mix_rate
	wav.stereo = false
	var count: int = maxi(roundi(seconds * mix_rate), 1)
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	for i: int in count:
		var sample: float = sin(TAU * frequency * float(i) / float(mix_rate)) * 0.4
		data.encode_s16(i * 2, roundi(sample * 32767.0))
	wav.data = data
	return wav
