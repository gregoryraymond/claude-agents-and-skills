---
name: audio
description: Guide for Bevy 0.15 audio — bevy_audio, spatial audio, music/SFX patterns, bevy_kira_audio alternative. Apply when adding or modifying sound effects, music, or audio systems.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 Audio Reference

**Load this skill when adding or modifying audio — sound effects, music, ambient sounds, or spatial audio.**

**Note:** This project does not yet have audio implemented. This skill provides the patterns for when you add it.

---

## Built-in bevy_audio

### Playing a Sound

```rust
// One-shot sound effect
commands.spawn((
    AudioPlayer::new(asset_server.load("sounds/explosion.ogg")),
    PlaybackSettings::ONCE,
));

// Looping background music
commands.spawn((
    AudioPlayer::new(asset_server.load("music/theme.ogg")),
    PlaybackSettings::LOOP,
));

// Despawn entity when sound finishes
commands.spawn((
    AudioPlayer::new(asset_server.load("sounds/click.ogg")),
    PlaybackSettings::DESPAWN,  // entity despawned after playback
));
```

### PlaybackSettings Presets

| Preset | Behavior |
|---|---|
| `ONCE` | Play once, keep entity |
| `LOOP` | Loop forever |
| `DESPAWN` | Play once, despawn entity when done |
| `REMOVE` | Play once, remove AudioPlayer component when done |

### Runtime Control via AudioSink

```rust
// AudioSink is auto-added after playback starts
fn control_music(sinks: Query<&AudioSink, With<MusicMarker>>) {
    for sink in &sinks {
        sink.set_volume(0.5);    // 0.0 to 1.0
        sink.pause();
        sink.play();
        sink.toggle();
        sink.set_speed(1.5);     // playback rate
        sink.stop();             // stop and remove
    }
}
```

### Global Volume

```rust
commands.insert_resource(GlobalVolume::new(0.8));
```

---

## Spatial Audio (3D)

```rust
// Listener (usually on the camera)
commands.spawn((
    Camera3d::default(),
    SpatialListener::default(),
    Transform::from_xyz(0.0, 10.0, 0.0),
));

// Spatial sound source
commands.spawn((
    AudioPlayer::new(asset_server.load("sounds/fire.ogg")),
    PlaybackSettings::LOOP,
    SpatialAudioSink::default(),
    Transform::from_xyz(5.0, 0.0, -3.0),
));

// Configure distance attenuation
commands.insert_resource(DefaultSpatialScale(SpatialScale::new(1.0 / 10.0)));
```

`SpatialAudioSink` replaces `AudioSink` for spatial sources — same API plus distance-based attenuation.

---

## Supported Formats

| Format | Feature Flag | Notes |
|---|---|---|
| OGG Vorbis | `vorbis` (default) | Best for music, good compression |
| WAV | `wav` | Uncompressed, good for short SFX |
| MP3 | `mp3` | Universal but patent-encumbered |
| FLAC | `flac` | Lossless, large files |

**Recommendation:** OGG for music, WAV for short SFX (low latency).

---

## bevy_kira_audio (Alternative)

If you need advanced audio features, consider `bevy_kira_audio`:

### Advantages
- Professional-grade mixing and effects
- Decibel-based volume with smooth transitions and easing
- Channel-based architecture for grouped audio control
- Playback rate manipulation (pitch shifting)
- Fluent API: `audio.play(asset).loop_from(0.5).fade_in(dur).with_panning(1.0)`

### Setup
```toml
# Cargo.toml — disable built-in audio
[dependencies]
bevy = { version = "0.15", default-features = false, features = [
    # list all features EXCEPT bevy_audio and vorbis
]}
bevy_kira_audio = "0.21"  # check compatibility
```

### Usage
```rust
fn play_music(audio: Res<Audio>, assets: Res<Assets<AudioSource>>) {
    audio.play(my_handle)
        .looped()
        .fade_in(AudioTween::linear(Duration::from_secs(2)))
        .with_volume(0.7);
}
```

**Recommendation:** Start with built-in `bevy_audio`. Switch to `bevy_kira_audio` only if you need crossfading, audio ducking, or per-channel mixing.

---

## Recommended Architecture for This Project

### Audio Plugin Pattern

```rust
pub struct GameAudioPlugin;

impl Plugin for GameAudioPlugin {
    fn build(&self, app: &mut App) {
        app
            .init_resource::<AudioSettings>()
            .add_systems(Startup, setup_audio)
            .add_systems(Update, (
                play_combat_sounds
                    .run_if(in_phase_fn(|p| matches!(p, GamePhase::CombatResolution))),
                play_ui_sounds,
                update_music_for_phase,
            ));
    }
}

#[derive(Resource)]
struct AudioSettings {
    master_volume: f32,
    music_volume: f32,
    sfx_volume: f32,
    music_enabled: bool,
    sfx_enabled: bool,
}
```

### Suggested Sound Categories

| Category | Examples | Playback |
|---|---|---|
| **Music** | Theme, in-game ambient, victory/defeat | Looping, crossfade on phase change |
| **UI SFX** | Button click, tab switch, notification | One-shot, DESPAWN |
| **Game SFX** | Combat hit, army march, building complete | One-shot or spatial |
| **Ambient** | Wind, ocean waves, city bustle | Looping, spatial, phase-gated |

### Phase-Based Music

```rust
fn update_music(
    state: Res<GameState>,
    mut current: Local<Option<GamePhase>>,
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    music_query: Query<Entity, With<MusicMarker>>,
) {
    if Some(state.phase) != *current {
        // Despawn current music
        for entity in &music_query {
            commands.entity(entity).despawn();
        }
        // Spawn new music for phase
        let track = match state.phase {
            GamePhase::Lobby => "music/menu_theme.ogg",
            GamePhase::PlayerTurn => "music/gameplay.ogg",
            GamePhase::CombatResolution => "music/combat.ogg",
            GamePhase::GameOver => "music/victory.ogg",
            _ => return,
        };
        commands.spawn((
            AudioPlayer::new(asset_server.load(track)),
            PlaybackSettings::LOOP,
            MusicMarker,
        ));
        *current = Some(state.phase);
    }
}
```

---

## Performance Tips

- Limit simultaneous sound sources (8-16 is typical for games)
- Use `DESPAWN` playback for one-shot sounds to prevent entity buildup
- Spatial audio adds per-source CPU cost — use sparingly for non-critical sounds
- Pre-load audio assets during loading screen, not on first play
