import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;
import 'package:nai_huishi/core/constants/api_constants.dart';
import 'package:nai_huishi/core/errors/exceptions.dart';
import 'package:nai_huishi/core/network/robust_http_adapter.dart';
import 'package:nai_huishi/core/utils/image_utils.dart';
import 'package:nai_huishi/domain/entities/generation_task.dart';
import 'package:nai_huishi/domain/entities/nai_model.dart';

class NovelAiApiService {
  final Dio _dio;
  final Dio _officialDio;

  /// 官方 API 日志缓冲区（最近 500 条）
  static final List<String> officialLogs = [];
  static const int _maxLogs = 500;

  NovelAiApiService(this._dio) : _officialDio = createSimpleDio();

  void _configureAuth(String apiKey, String baseUrl) {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    _dio.options.baseUrl = normalizedBaseUrl;
    _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    _dio.options.headers['Content-Type'] = 'application/json';
    _dio.options.headers['Accept'] = 'application/json';
  }

  /// 配置官方 API 专用 Dio（使用系统 DNS，不经过 DoH）
  void _configureOfficialAuth(String apiKey) {
    _officialDio.options.baseUrl = ApiConstants.naiOfficialBaseUrl;
    _officialDio.options.headers['Authorization'] = 'Bearer $apiKey';
    _officialDio.options.headers['Content-Type'] = 'application/json';
    // 反滥用校验
    _officialDio.options.headers['Origin'] = 'https://novelai.net';
    _officialDio.options.headers['Referer'] = 'https://novelai.net';
    // 不设全局 Accept，各请求方法自行设置
    _officialDio.options.headers.remove('Accept');
  }

  String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/v1')) {
      return trimmed.substring(0, trimmed.length - 3);
    }
    return trimmed;
  }

  Future<List<NaiModel>> fetchModels(String apiKey, String baseUrl) async {
    _configureAuth(apiKey, baseUrl);
    try {
      final response = await _dio.get(ApiConstants.models);
      final data = response.data;

      if (data is Map<String, dynamic> && data.containsKey('data')) {
        final List list = data['data'];
        return list.map((e) => NaiModel(
          id: e['id'] ?? '',
          name: e['id'] ?? '',
          description: e['object'] ?? '',
          type: e['owned_by'] ?? '',
        )).toList();
      }

      return [];
    } on DioException catch (e) {
      throw ApiException(
        message: _handleDioError(e),
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  Future<GenerationTask> generateImage(GenerationTask task, String apiKey, String baseUrl) async {
    _configureAuth(apiKey, baseUrl);

    try {
      final requestBody = _buildChatCompletionsBody(task);
      final response = await _dio.post(
        ApiConstants.chatCompletions,
        data: requestBody,
        options: Options(
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 1),
        ),
      );

      final parsed = _parseResponse(response.data, task);
      return await _downloadIfNeeded(parsed, apiKey);
    } on DioException catch (e) {
      throw ApiException(
        message: _handleDioError(e),
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  Future<GenerationTask> inpaintImage(GenerationTask task, String apiKey, String baseUrl) async {
    _configureAuth(apiKey, baseUrl);

    print('[NAI] === INPAINT START ===');
    print('[NAI] baseUrl: ${_dio.options.baseUrl}');
    print('[NAI] sourceImage: ${task.sourceImagePath}');
    print('[NAI] maskImage: ${task.maskImagePath}');
    print('[NAI] prompt: ${task.prompt}');
    print('[NAI] model: ${task.model}');
    print('[NAI] strength: ${task.inpaintStrength}');
    print('[NAI] size: ${task.width}x${task.height}');

    final sourceBytes = await File(task.sourceImagePath!).readAsBytes();
    final maskBytes = await File(task.maskImagePath!).readAsBytes();
    final alphaSourceBytes = _applyMaskToImageAlpha(sourceBytes, maskBytes);

    print('[NAI] sourceBytes length: ${sourceBytes.length}');
    print('[NAI] maskBytes length: ${maskBytes.length}');
    print('[NAI] alphaSourceBytes length: ${alphaSourceBytes.length}');

    // /v1/images/edits: 不传 mask，使用 image alpha 通道；透明区域会被转换为 NovelAI 白色重绘区域
    final formData = FormData.fromMap({
      'model': task.model,
      'prompt': task.prompt,
      'image': MultipartFile.fromBytes(alphaSourceBytes, filename: 'source_alpha.png'),
      'size': '${task.width}x${task.height}',
      'response_format': 'b64_json',
    });

    print('[NAI] sending alpha image as multipart/form-data to /v1/images/edits');

    try {
      final response = await _dio.post(
        ApiConstants.imageEdits,
        data: formData,
        options: Options(
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 2),
          headers: {
            'Authorization': 'Bearer $apiKey',
          },
        ),
      );

      print('[NAI] response statusCode: ${response.statusCode}');
      print('[NAI] response data type: ${response.data.runtimeType}');
      if (response.data is Map) {
        print('[NAI] response keys: ${(response.data as Map).keys.toList()}');
        final data = response.data as Map<String, dynamic>;
        if (data.containsKey('data')) {
          final dataList = data['data'] as List?;
          print('[NAI] response data[].length: ${dataList?.length}');
          if (dataList != null && dataList.isNotEmpty) {
            final first = dataList.first;
            if (first is Map) {
              print('[NAI] response data[0] keys: ${first.keys.toList()}');
              if (first.containsKey('b64_json')) {
                print('[NAI] response data[0].b64_json length: ${(first['b64_json'] as String?)?.length}');
              }
              if (first.containsKey('url')) {
                print('[NAI] response data[0].url: ${first['url']}');
              }
            }
          }
        }
      }

      final parsed = await _parseInpaintingResponse(response.data, task);
      print('[NAI] parsed status: ${parsed.status}, imagePath: ${parsed.imagePath}, imageUrl: ${parsed.imageUrl}');
      return parsed;
    } on DioException catch (e) {
      print('[NAI] DioException: ${e.type}, statusCode: ${e.response?.statusCode}');
      print('[NAI] DioException response: ${e.response?.data}');
      throw ApiException(
        message: _handleDioError(e),
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  List<int> _applyMaskToImageAlpha(List<int> sourceBytes, List<int> maskBytes) {
    final source = img.decodeImage(Uint8List.fromList(sourceBytes));
    final mask = img.decodeImage(Uint8List.fromList(maskBytes));
    if (source == null || mask == null) {
      return sourceBytes;
    }

    final output = img.Image.from(source);
    final resizedMask = mask.width == output.width && mask.height == output.height
        ? mask
        : img.copyResize(mask, width: output.width, height: output.height, interpolation: img.Interpolation.nearest);

    int transparentPixels = 0;
    for (int y = 0; y < output.height; y++) {
      for (int x = 0; x < output.width; x++) {
        final maskPixel = resizedMask.getPixel(x, y);
        final shouldRepaint = maskPixel.r > 127 || maskPixel.g > 127 || maskPixel.b > 127 || maskPixel.a < 128;
        final sourcePixel = output.getPixel(x, y);
        output.setPixelRgba(
          x,
          y,
          sourcePixel.r,
          sourcePixel.g,
          sourcePixel.b,
          shouldRepaint ? 0 : 255,
        );
        if (shouldRepaint) transparentPixels++;
      }
    }

    final totalPixels = output.width * output.height;
    print('[NAI] alpha source transparent pixels: $transparentPixels / $totalPixels (${(transparentPixels / totalPixels * 100).toStringAsFixed(2)}%)');
    return img.encodePng(output);
  }

  Map<String, dynamic> _buildChatCompletionsBody(GenerationTask task) {
    final messages = <Map<String, dynamic>>[];

    // 方式二：JSON 结构化提示词
    messages.add({
      'role': 'user',
      'content': _buildStructuredPrompt(task),
    });

    // 方式三：负面提示词通过 system 消息传递
    if (task.negativePrompt != null && task.negativePrompt!.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': 'Negative prompt: ${task.negativePrompt}',
      });
    }

    // 方式三：多人物坐标通过 system 消息传递
    if (task.characters != null && task.characters!.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': _buildCharactersPrompt(task.characters!),
      });
    }

    return {
      'model': task.model,
      'stream': false,
      'scale': task.scale,
      'cfg_rescale': task.cfgRescale,
      'width': task.width,
      'height': task.height,
      'sampler': task.sampler,
      'noise_schedule': task.noiseSchedule,
      if (task.seed != null) 'seed': task.seed,
      'messages': messages,
    };
  }

  Future<Map<String, dynamic>> _buildInpaintingBody(GenerationTask task) async {
    if (task.sourceImagePath == null || task.maskImagePath == null) {
      throw Exception('局部重绘缺少原图或遮罩图');
    }

    final sourceBytes = await File(task.sourceImagePath!).readAsBytes();
    final maskBytes = await File(task.maskImagePath!).readAsBytes();

    final imageBase64 = base64Encode(sourceBytes);
    final maskBase64 = base64Encode(maskBytes);

    return {
      'model': task.model,
      'prompt': task.prompt,
      'image': imageBase64,
      'mask': maskBase64,
      'strength': task.inpaintStrength ?? 1.0,
      if (task.seed != null) 'seed': task.seed,
      'size': '${task.width}x${task.height}',
      if (task.negativePrompt != null && task.negativePrompt!.isNotEmpty) 'negative_prompt': task.negativePrompt,
      'steps': ApiConstants.defaultInpaintingSteps,
      'scale': task.scale,
      'cfg_rescale': task.cfgRescale,
      'sampler': task.sampler,
      'noise_schedule': task.noiseSchedule,
      'n': 1,
      'response_format': 'b64_json',
    };
  }

  String _buildStructuredPrompt(GenerationTask task) {
    return jsonEncode({
      'prompt': task.prompt,
      'size': [task.width, task.height],
    });
  }

  String _buildCharactersPrompt(List<CharacterSpec> characters) {
    final payload = characters.where((c) => c.enabled).map((c) {
      final map = <String, dynamic>{
        'prompt': c.prompt,
      };
      if (c.centerX != null && c.centerY != null) {
        map['center'] = {
          'x': c.centerX,
          'y': c.centerY,
        };
      }
      if (c.uc != null && c.uc!.isNotEmpty) {
        map['uc'] = c.uc;
      }
      return map;
    }).toList();

    return 'Characters: ${jsonEncode(payload)}';
  }

  Future<GenerationTask> _parseInpaintingResponse(dynamic data, GenerationTask originalTask) async {
    if (data is Map<String, dynamic>) {
      final images = data['data'] as List<dynamic>?;
      if (images != null && images.isNotEmpty) {
        final imageData = images.first;
        if (imageData is Map<String, dynamic>) {
          if (imageData['url'] is String) {
            return originalTask.copyWith(
              status: 'success',
              imageUrl: imageData['url'] as String,
              completedAt: DateTime.now(),
            );
          }
          if (imageData['b64_json'] is String) {
            final filename = ImageUtils.generateFilename();
            final filePath = await ImageUtils.saveBase64Image(imageData['b64_json'] as String, filename);
            return originalTask.copyWith(
              status: 'success',
              imagePath: filePath,
              completedAt: DateTime.now(),
            );
          }
        }
      }
    }

    return originalTask.copyWith(
      status: 'failed',
      errorMessage: '未能从局部重绘响应中提取图片',
      completedAt: DateTime.now(),
    );
  }

  GenerationTask _parseResponse(dynamic data, GenerationTask originalTask) {
    String? imageUrl;
    String? imagePath;

    if (data is Map<String, dynamic>) {
      final choices = data['choices'] as List<dynamic>?;
      if (choices != null && choices.isNotEmpty) {
        final message = choices[0]['message'];
        if (message != null) {
          final content = message['content'];
          if (content is String) {
            imageUrl = ImageUtils.extractImageUrlFromMarkdown(content);
          } else if (content is List) {
            for (final part in content) {
              if (part is Map<String, dynamic>) {
                if (part['type'] == 'image_url') {
                  imageUrl = part['image_url']?['url'];
                  break;
                } else if (part['type'] == 'text') {
                  imageUrl = ImageUtils.extractImageUrlFromMarkdown(part['text'] ?? '');
                  if (imageUrl != null) break;
                }
              }
            }
          }
        }
      }

      if (imageUrl == null) {
        final images = data['data'] as List<dynamic>?;
        if (images != null && images.isNotEmpty) {
          final imageData = images[0];
          if (imageData is Map<String, dynamic>) {
            if (imageData.containsKey('url')) {
              imageUrl = imageData['url'];
            } else if (imageData.containsKey('b64_json')) {
              imagePath = null;
            }
          }
        }
      }
    }

    return originalTask.copyWith(
      status: imageUrl != null || imagePath != null ? 'success' : 'failed',
      imageUrl: imageUrl,
      imagePath: imagePath,
      errorMessage: imageUrl == null && imagePath == null ? '未能从响应中提取图片' : null,
      completedAt: DateTime.now(),
    );
  }

  Future<GenerationTask> _downloadIfNeeded(GenerationTask task, String apiKey) async {
    if (task.imageUrl != null && task.imagePath == null) {
      try {
        final filename = ImageUtils.generateFilename();
        final dir = await ImageUtils.getImageDirectory();
        final filePath = '${dir.path}${Platform.pathSeparator}$filename';
        await _dio.download(
          task.imageUrl!,
          filePath,
          options: Options(
            receiveTimeout: const Duration(minutes: 5),
            headers: {
              'Authorization': 'Bearer $apiKey',
            },
          ),
        );
        return task.copyWith(imagePath: filePath);
      } catch (_) {
        return task;
      }
    }
    return task;
  }

  Future<bool> testConnection(String apiKey, String baseUrl) async {
    _configureAuth(apiKey, baseUrl);
    try {
      final response = await _dio.post(
        ApiConstants.chatCompletions,
        data: {
          'model': 'nai-diffusion-4-5-curated',
          'stream': false,
          'width': 832,
          'height': 1216,
          'messages': [
            {
              'role': 'user',
              'content': jsonEncode({
                'prompt': '1girl',
                'size': [832, 1216],
              }),
            },
          ],
        },
        options: Options(receiveTimeout: const Duration(seconds: 20)),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ──────────── NovelAI 官方 API 直连 ────────────

  /// 文生图（官方原生格式）
  Future<GenerationTask> generateImageOfficial(
    GenerationTask task,
    String apiKey,
  ) async {
    _configureOfficialAuth(apiKey);

    try {
      final body = _buildOfficialBody(task);
      final response = await _officialDio.post(
        ApiConstants.naiOfficialTxt2Img,
        data: body,
        options: Options(
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 1),
          responseType: ResponseType.bytes, // 官方返回 ZIP 二进制
          headers: {'Accept': 'application/zip'},
        ),
      );

      return await _parseOfficialImageResponse(response.data, task);
    } on DioException catch (e) {
      throw ApiException(
        message: _handleDioError(e),
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// 图生图 / 局部重绘（官方原生格式）
  Future<GenerationTask> img2imgOfficial(
    GenerationTask task,
    String apiKey,
  ) async {
    _configureOfficialAuth(apiKey);

    try {
      // 先上传原图
      final sourceBytes = await File(task.sourceImagePath!).readAsBytes();
      final uploadUuid = await _uploadImageOfficial(sourceBytes, apiKey);

      String? maskUuid;
      if (task.maskImagePath != null) {
        final maskBytes = await File(task.maskImagePath!).readAsBytes();
        maskUuid = await _uploadImageOfficial(maskBytes, apiKey);
      }

      final body = _buildOfficialBody(task, imageUuid: uploadUuid, maskUuid: maskUuid);
      final response = await _officialDio.post(
        ApiConstants.naiOfficialImg2Img,
        data: body,
        options: Options(
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 2),
          responseType: ResponseType.bytes,
          headers: {'Accept': 'application/zip'},
        ),
      );

      return await _parseOfficialImageResponse(response.data, task);
    } on DioException catch (e) {
      throw ApiException(
        message: _handleDioError(e),
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// 上传图片到 NAI 官方，返回 uuid
  Future<String> _uploadImageOfficial(List<int> imageBytes, String apiKey) async {
    _configureOfficialAuth(apiKey);

    final formData = FormData.fromMap({
      'image': MultipartFile.fromBytes(imageBytes, filename: 'image.png'),
    });

    final response = await _officialDio.post(
      ApiConstants.naiOfficialUpload,
      data: formData,
      options: Options(
        sendTimeout: const Duration(seconds: 30),
      ),
    );

    final data = response.data as Map<String, dynamic>;
    return data['uuid'] as String;
  }

  /// 构建 NAI 官方请求体
  Map<String, dynamic> _buildOfficialBody(
    GenerationTask task, {
    String? imageUuid,
    String? maskUuid,
  }) {
    // NAI 官方 API 使用 action / legacy 两种模式
    // 这里使用 action="generate" 模式
    final isV4Model = task.model.startsWith('nai-diffusion-4');

    final params = <String, dynamic>{
      'width': task.width,
      'height': task.height,
      'scale': task.scale,
      'cfg_rescale': task.cfgRescale,
      'sampler': task.sampler,
      'noise_schedule': task.noiseSchedule,
      'steps': task.steps,
      'n_samples': 1,
      if (task.seed != null) 'seed': task.seed,
      if (task.negativePrompt != null && task.negativePrompt!.isNotEmpty)
        'negative_prompt': task.negativePrompt,
    };

    if (isV4Model) {
      // V4 模型必需字段
      params['params_version'] = 3;
      params['legacy'] = false;
      params['legacy_v3_extend'] = false;
      params['legacy_uc'] = false;
      params['ucPreset'] = 0;
      params['v4_prompt'] = {
        'caption': {
          'base_caption': task.prompt,
          'char_captions': [],
        },
        'use_coords': true,
        'use_order': true,
      };
      params['v4_negative_prompt'] = {
        'caption': {
          'base_caption': task.negativePrompt ?? '',
          'char_captions': [],
        },
        'legacy_uc': false,
      };
      params['characterPrompts'] = [];
      params['reference_image_multiple'] = [];
      params['reference_information_extracted_multiple'] = [];
      params['reference_strength_multiple'] = [];
      params['skip_cfg_above_sigma'] = null;
      params['sm'] = false;
      params['sm_dyn'] = false;
      params['autoSmea'] = false;
      params['dynamic_thresholding'] = false;
      params['controlnet_strength'] = 1.0;
      params['normalize_reference_strength_multiple'] = true;
      params['add_original_image'] = true;
      params['use_coords'] = true;
      params['use_order'] = true;
      params['inpaintImg2ImgStrength'] = 1;
      params['deliberate_euler_ancestral_bug'] = false;
    }

    if (imageUuid != null) {
      params['image'] = imageUuid;
      params['strength'] = task.inpaintStrength ?? 0.7;
    }
    if (maskUuid != null) {
      params['mask'] = maskUuid;
    }

    // prefer_brownian / qualityToggle 必须放在 parameters 内部
    params['prefer_brownian'] = true;
    params['qualityToggle'] = true;

    return {
      'input': task.prompt,
      'model': task.model,
      'action': 'generate',
      'parameters': params,
    };
  }

  /// 解析官方 API 响应（ZIP → PNG）
  /// 从 NAI 官方响应体中提取 PNG 图片
  /// NAI 官方返回 ZIP 包（Content-Type: application/zip）
  Future<GenerationTask> _parseOfficialImageResponse(
    List<int> bytes,
    GenerationTask originalTask,
  ) async {
    try {
      List<int> pngBytes;

      // 检测 ZIP 格式（PK\x03\x04）
      if (bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04) {
        // 用 archive 包解压 ZIP，提取第一张 PNG
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          if (file.isFile && file.name.endsWith('.png')) {
            pngBytes = file.content.toList();
            return await _savePng(pngBytes, originalTask);
          }
        }
        // ZIP 中没有 PNG 文件
        throw Exception('ZIP 包中未找到 PNG 文件');
      }

      // 检测 GZip 格式（0x1F 0x8B）
      if (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
        final gunzipped = GZipCodec().decode(bytes);
        // 检查是否解压后是 ZIP
        if (gunzipped.length > 4 &&
            gunzipped[0] == 0x50 &&
            gunzipped[1] == 0x4B &&
            gunzipped[2] == 0x03 &&
            gunzipped[3] == 0x04) {
          final archive = ZipDecoder().decodeBytes(gunzipped);
          for (final file in archive) {
            if (file.isFile && file.name.endsWith('.png')) {
              pngBytes = file.content.toList();
              return await _savePng(pngBytes, originalTask);
            }
          }
        }
        // 解压后直接是 PNG
        if (gunzipped.length > 4 &&
            gunzipped[0] == 0x89 &&
            gunzipped[1] == 0x50 &&
            gunzipped[2] == 0x4E &&
            gunzipped[3] == 0x47) {
          return await _savePng(gunzipped, originalTask);
        }
      }

      // 直接是 PNG
      if (bytes.length > 4 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return await _savePng(bytes, originalTask);
      }

      throw Exception('无法识别的响应格式 (未找到 ZIP/GZip/PNG 文件头)');
    } catch (e) {
      return originalTask.copyWith(
        status: 'failed',
        errorMessage: '解析官方 API 响应失败: $e',
        completedAt: DateTime.now(),
      );
    }
  }

  /// 将 PNG 字节保存到文件
  Future<GenerationTask> _savePng(
    List<int> pngBytes,
    GenerationTask task,
  ) async {
    final filename = ImageUtils.generateFilename();
    final dir = await ImageUtils.getImageDirectory();
    final filePath = '${dir.path}${Platform.pathSeparator}$filename';
    await File(filePath).writeAsBytes(pngBytes, flush: true);
    return task.copyWith(
      status: 'success',
      imagePath: filePath,
      completedAt: DateTime.now(),
    );
  }

  /// 测试 NAI 官方连接
  Future<bool> testConnectionOfficial(String apiKey) async {
    _configureOfficialAuth(apiKey);
    try {
      final response = await _officialDio.post(
        ApiConstants.naiOfficialTxt2Img,
        data: {
          'input': 'test',
          'model': 'nai-diffusion-4-5-curated',
          'action': 'generate',
          'parameters': {
            'width': 832,
            'height': 1216,
            'scale': 5.0,
            'steps': 28,
            'n_samples': 1,
            'qualityToggle': false,
            'prefer_brownian': false,
            // V4 必需
            'params_version': 3,
            'legacy': false,
            'ucPreset': 0,
            'v4_prompt': {
              'caption': {'base_caption': 'test', 'char_captions': []},
              'use_coords': true,
              'use_order': true,
            },
            'v4_negative_prompt': {
              'caption': {'base_caption': '', 'char_captions': []},
              'legacy_uc': false,
            },
            'characterPrompts': [],
          },
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 30),
          responseType: ResponseType.bytes,
        ),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 记录官方 API 日志
  void _addLog(String msg) {
    final ts = DateTime.now().toIso8601String();
    officialLogs.add('[$ts] $msg');
    if (officialLogs.length > _maxLogs) {
      officialLogs.removeAt(0);
    }
  }

  /// 查询 NovelAI 订阅 Anlas 余额
  Future<int> fetchAnlasBalance(String apiKey) async {
    try {
      final response = await _officialDio.get(
        '${ApiConstants.naiApiBaseUrl}/user/subscription',
        options: Options(
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Origin': 'https://novelai.net',
            'Referer': 'https://novelai.net',
          },
        ),
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        final balance = (data['training'] as num?)?.toInt() ?? -1;
        print('[Anlas余额] 查询成功: $balance');
        return balance;
      }
      print('[Anlas余额] 响应类型异常: ${data.runtimeType}');
      return -2;
    } on DioException catch (e) {
      final errMsg = _handleDioError(e);
      _addLog('[余额查询失败] $errMsg');
      print('[Anlas余额] 请求失败: $errMsg (status=${e.response?.statusCode}, body=${e.response?.data})');
      return -3;
    }
  }

  // ──────────── 已有方法 ────────────

  String _handleDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时，请检查网络连接';
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        final body = e.response?.data;
        if (statusCode == 401) return 'API Key 无效或已过期';
        if (statusCode == 402) return '额度不足 (Anlas)';
        if (statusCode == 429) return '请求过于频繁，请稍后再试';
        if (statusCode == 500) return '服务器内部错误';
        // 尝试提取 NAI 错误消息体（可能为 bytes 或 JSON）
        String bodyMsg = '';
        if (body is Map) {
          bodyMsg = body['error']?['message']?.toString() ?? body.toString();
        } else if (body is List<int> && body.length < 500) {
          try {
            bodyMsg = utf8.decode(body);
          } catch (_) {
            bodyMsg = '(${body.length} bytes)';
          }
        } else if (body != null) {
          bodyMsg = body.toString();
        }
        return '请求失败 ($statusCode): $bodyMsg';
      case DioExceptionType.connectionError:
        return '无法连接到服务器，请检查 Base URL';
      default:
        return '网络错误: ${e.message}';
    }
  }

  /// 判断是否为端点不可用错误（404 或 Invalid URL）
  bool _isEndpointUnavailable(DioException e) {
    final statusCode = e.response?.statusCode;
    if (statusCode == 404) {
      return true;
    }

    final body = e.response?.data;
    if (body is String && body.contains('Invalid URL')) {
      return true;
    }
    if (body is Map) {
      final errorStr = body['error']?.toString() ?? body['message']?.toString() ?? '';
      if (errorStr.contains('Invalid URL')) {
        return true;
      }
      // 有些中转站返回 { "detail": "Invalid URL ..." }
      final detailStr = body['detail']?.toString() ?? '';
      if (detailStr.contains('Invalid URL')) {
        return true;
      }
    }

    return false;
  }
}
