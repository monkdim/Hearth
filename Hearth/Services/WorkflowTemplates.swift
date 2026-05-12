import Foundation

/// Bundled ComfyUI workflow templates. Users paste these into the sidecar
/// editor as a starting point and edit to match their installation (model
/// filenames, custom-node names, etc.). Every template has a `{prompt}`
/// placeholder Hearth substitutes at submission time.
enum WorkflowTemplates {
    struct Template: Identifiable, Hashable {
        let id: String
        let title: String
        let output: SidecarOutput
        let blurb: String
        let json: String
    }

    static var all: [Template] { [Self.fluxImage, Self.mochiVideo, Self.musicGen] }

    // MARK: - Flux image (Schnell, 4-step)

    static let fluxImage = Template(
        id: "flux-schnell-image",
        title: "Flux Schnell image (1024×1024)",
        output: .image,
        blurb: "Requires Flux.1-Schnell + clip_l + t5xxl_fp8 + ae.safetensors in ComfyUI's models folders.",
        json: #"""
        {
          "5": {
            "class_type": "EmptyLatentImage",
            "inputs": { "width": 1024, "height": 1024, "batch_size": 1 }
          },
          "6": {
            "class_type": "CLIPTextEncode",
            "inputs": { "text": "{prompt}", "clip": ["11", 0] }
          },
          "8": {
            "class_type": "VAEDecode",
            "inputs": { "samples": ["13", 0], "vae": ["10", 0] }
          },
          "9": {
            "class_type": "SaveImage",
            "inputs": { "filename_prefix": "hearth", "images": ["8", 0] }
          },
          "10": {
            "class_type": "VAELoader",
            "inputs": { "vae_name": "ae.safetensors" }
          },
          "11": {
            "class_type": "DualCLIPLoader",
            "inputs": {
              "clip_name1": "t5xxl_fp8_e4m3fn.safetensors",
              "clip_name2": "clip_l.safetensors",
              "type": "flux"
            }
          },
          "12": {
            "class_type": "UNETLoader",
            "inputs": { "unet_name": "flux1-schnell.safetensors", "weight_dtype": "fp8_e4m3fn" }
          },
          "13": {
            "class_type": "KSampler",
            "inputs": {
              "seed": 0,
              "steps": 4,
              "cfg": 1.0,
              "sampler_name": "euler",
              "scheduler": "simple",
              "denoise": 1.0,
              "model": ["12", 0],
              "positive": ["6", 0],
              "negative": ["6", 0],
              "latent_image": ["5", 0]
            }
          }
        }
        """#
    )

    // MARK: - Mochi video (text-to-video)

    static let mochiVideo = Template(
        id: "mochi-t2v",
        title: "Mochi text-to-video (short clip)",
        output: .video,
        blurb: "Needs ComfyUI-Mochi custom nodes installed and Mochi weights downloaded. Expect 30+ GB unified memory for full quality — heavy.",
        json: #"""
        {
          "1": {
            "class_type": "MochiTextEncode",
            "inputs": { "text": "{prompt}" }
          },
          "2": {
            "class_type": "MochiSampler",
            "inputs": {
              "text_embed": ["1", 0],
              "steps": 50,
              "cfg": 6.0,
              "seed": 0,
              "frames": 25,
              "width": 848,
              "height": 480
            }
          },
          "3": {
            "class_type": "MochiVAEDecode",
            "inputs": { "samples": ["2", 0] }
          },
          "4": {
            "class_type": "VHS_VideoCombine",
            "inputs": {
              "images": ["3", 0],
              "frame_rate": 24,
              "filename_prefix": "hearth_mochi",
              "format": "video/h264-mp4"
            }
          }
        }
        """#
    )

    // MARK: - MusicGen audio

    static let musicGen = Template(
        id: "musicgen-audio",
        title: "MusicGen audio clip",
        output: .audio,
        blurb: "Needs ComfyUI audio extensions (e.g., comfyui-audio-pack or ComfyUI-MusicGen). Names of nodes vary by extension — adapt to yours.",
        json: #"""
        {
          "1": {
            "class_type": "MusicGenLoader",
            "inputs": { "model": "facebook/musicgen-medium" }
          },
          "2": {
            "class_type": "MusicGenSampler",
            "inputs": {
              "model": ["1", 0],
              "prompt": "{prompt}",
              "duration": 8,
              "guidance": 3.0,
              "seed": 0
            }
          },
          "3": {
            "class_type": "SaveAudio",
            "inputs": {
              "audio": ["2", 0],
              "filename_prefix": "hearth_musicgen"
            }
          }
        }
        """#
    )
}
