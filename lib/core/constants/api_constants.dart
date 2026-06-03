class ApiConstants {
  ApiConstants._();

  // 默认 NovelAI Gateway 地址（留空，用户必须自行填写中转站地址）
  static const String defaultBaseUrl = '';

  // API 路径
  static const String chatCompletions = '/v1/chat/completions';
  static const String imageGenerations = '/v1/images/generations';
  static const String imageInpainting = '/v1/images/inpainting';
  static const String imageEdits = '/v1/images/edits';
  static const String models = '/v1/models';

  // Nano Banana 支持的宽高比（用于 imageConfig.aspectRatio）
  static const List<String> nanoSupportedSizes = [
    '1:1',
    '16:9',
    '9:16',
    '4:3',
    '3:4',
    '3:2',
    '2:3',
  ];

  static const Map<String, String> nanoSizeLabels = {
    '1:1':  '1:1 正方形',
    '16:9': '16:9 横版宽屏',
    '9:16': '9:16 竖版',
    '4:3':  '4:3 横版',
    '3:4':  '3:4 竖版',
    '3:2':  '3:2 横版',
    '2:3':  '2:3 竖版',
  };

  // Nano Banana 支持的图片尺寸（用于 imageConfig.imageSize）
  static const List<String> nanoImageSizes = ['1K', '2K', '4K'];

  static const Map<String, String> nanoImageSizeLabels = {
    '1K': '1K 标准',
    '2K': '2K 高清',
    '4K': '4K 超清',
  };

  // 支持的画幅
  static const Map<String, Map<String, int>> supportedResolutions = {
    '832x1216': {'width': 832, 'height': 1216},
    '1216x832': {'width': 1216, 'height': 832},
    '1024x1024': {'width': 1024, 'height': 1024},
  };

  // GPT Image 支持的画幅
  static const List<String> gptSupportedSizes = [
    '1024x1024',
    '1536x1024',
    '1024x1536',
    '2048x2048',
    '2048x1152',
    '3840x2160',
    '2160x3840',
    'auto',
  ];

  static const Map<String, String> gptSizeLabels = {
    '1024x1024': '1024×1024 正方形',
    '1536x1024': '1536×1024 横版',
    '1024x1536': '1024×1536 竖版',
    '2048x2048': '2048×2048 2K正方形',
    '2048x1152': '2048×1152 2K横版',
    '3840x2160': '3840×2160 4K横版',
    '2160x3840': '2160×3840 4K竖版',
    'auto': 'auto 默认',
  };

  // 支持的采样器
  static const List<String> supportedSamplers = [
    'k_euler',
    'k_euler_ancestral',
    'k_dpmpp_2m',
    'k_dpmpp_2s_ancestral',
    'k_dpmpp_sde',
    'ddim',
    'ddim_v3',
  ];

  // 支持的 noise_schedule
  static const List<String> supportedNoiseSchedules = [
    'native',
    'karras',
    'exponential',
    'polyexponential',
  ];

  // 默认参数
  static const double defaultScale = 5.0;
  static const double defaultCfgRescale = 0.0;
  static const String defaultSampler = 'k_euler';
  static const String defaultNoiseSchedule = 'native';
  static const int defaultSteps = 28;
  static const int defaultInpaintingSteps = 23;
  static const String defaultResolution = '832x1216';

  // ===== NovelAI 官方 API =====
  static const String naiOfficialBaseUrl = 'https://image.novelai.net';

  /// NovelAI 官方 API 支持的画幅分组（V4.5 按尺寸分类）
  static const Map<String, Map<String, Map<String, int>>> naiOfficialResolutionGroups = {
    '小型': {
      '肖像': {'width': 512, 'height': 768},
      '风景': {'width': 768, 'height': 512},
      '方形': {'width': 640, 'height': 640},
    },
    '普通': {
      '肖像': {'width': 832, 'height': 1216},
      '风景': {'width': 1216, 'height': 832},
      '方形': {'width': 1024, 'height': 1024},
    },
    '壁纸': {
      '肖像': {'width': 1088, 'height': 1920},
      '风景': {'width': 1920, 'height': 1088},
    },
    '大型': {
      '肖像': {'width': 1024, 'height': 1536},
      '风景': {'width': 1536, 'height': 1024},
      '广场': {'width': 1472, 'height': 1472},
    },
  };

  /// NovelAI 官方 API 支持的画幅（比中转站多得多）
  static const Map<String, Map<String, int>> naiOfficialSupportedResolutions = {
    '384x640': {'width': 384, 'height': 640},
    '512x768': {'width': 512, 'height': 768},
    '512x1024': {'width': 512, 'height': 1024},
    '576x960': {'width': 576, 'height': 960},
    '640x640': {'width': 640, 'height': 640},
    '640x1152': {'width': 640, 'height': 1152},
    '768x768': {'width': 768, 'height': 768},
    '768x1152': {'width': 768, 'height': 1152},
    '768x1280': {'width': 768, 'height': 1280},
    '832x1088': {'width': 832, 'height': 1088},
    '832x1216': {'width': 832, 'height': 1216},
    '864x1152': {'width': 864, 'height': 1152},
    '864x1536': {'width': 864, 'height': 1536},
    '896x1152': {'width': 896, 'height': 1152},
    '896x1280': {'width': 896, 'height': 1280},
    '1088x832': {'width': 1088, 'height': 832},
    '1152x768': {'width': 1152, 'height': 768},
    '1152x864': {'width': 1152, 'height': 864},
    '1152x896': {'width': 1152, 'height': 896},
    '1216x832': {'width': 1216, 'height': 832},
    '1280x768': {'width': 1280, 'height': 768},
    '1280x896': {'width': 1280, 'height': 896},
    '1536x640': {'width': 1536, 'height': 640},
    '1536x864': {'width': 1536, 'height': 864},
    '1536x1024': {'width': 1536, 'height': 1024},
    '1024x1024': {'width': 1024, 'height': 1024},
    '1024x1536': {'width': 1024, 'height': 1536},
  };
  static const String naiOfficialTxt2Img = '/ai/generate-image';
  static const String naiOfficialImg2Img = '/ai/generate-image';
  static const String naiOfficialUpload = '/ai/upload-image';
  static const String naiOfficialSubscription = '/ai/user/subscription';

  /// NovelAI 官方 API 支持的模型（不含中转站自定义模型）
  static const List<String> naiOfficialModels = [
    'nai-diffusion-4-5-curated',
    'nai-diffusion-4-5-full',
    'nai-diffusion-4-5-anime-curated',
    'nai-diffusion-4-5-anime-full',
    'nai-diffusion-4',
    'nai-diffusion-3',
    'nai-diffusion-furry-3',
    'kunoichi-1.1',
    'vibe-transfer',
  ];
}
