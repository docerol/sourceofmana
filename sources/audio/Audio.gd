extends AudioStreamPlayer

const DefaultTrack : String				= "LaJohanne"

var currentTrack : int					= DB.UnknownHash
var soundStream : AudioStreamOggVorbis	= null

#
func Stop():
	if is_playing():
		stop()
	currentTrack = DB.UnknownHash

func Load(soundID : int):
	if currentTrack != soundID:
		if soundStream:
			soundStream = null
			currentTrack = DB.UnknownHash

		var soundData : FileData = DB.MusicDB.get(soundID, null)
		if not soundData:
			# SOM-IDLE web-slim: a trilha pode não estar no pck (música excluída do
			# export web por peso — hoje nada a toca). Nunca derrubar o cliente.
			Util.PrintLog("Audio", "music track not present: %s" % str(soundID))
			return

		soundStream = soundData._resource as AudioStreamOggVorbis
		if not soundStream:
			Util.PrintLog("Audio", "music stream failed to load: %s" % str(soundData._name))
			return

		soundStream.set_loop(true)
		set_stream(soundStream)
		currentTrack = soundID

		set_autoplay(true)
		play()

func SetVolume(volume : float):
	set_volume_db(volume)

func Warped():
	if Launcher.Map.currentMapNode:
		var mapName : String = Launcher.Map.currentMapNode.get_meta("music", "")
		if not mapName.is_empty():
			Load(mapName.hash())
	else:
		Stop()

func PlayDefault():
	if DB.isInitialized and currentTrack == DB.UnknownHash:
		Load(DefaultTrack.hash())

#
func _post_launch():
	if not Launcher.dbInitialized.is_connected(PlayDefault):
		Launcher.dbInitialized.connect(PlayDefault)
	if Launcher.Map and not Launcher.Map.PlayerWarped.is_connected(Warped):
		Launcher.Map.PlayerWarped.connect(Warped)
		Warped()
