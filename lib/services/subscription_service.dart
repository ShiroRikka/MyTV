import 'dart:convert';

import 'package:luna_tv/models/search_resource.dart';

// v2.4.5: base58 (Bitcoin alphabet) 解码, 跟 web `bs58` npm 包 1:1.
//   之前是个 stub — 注释自己写着「最小兼容：直接把源字符串按 UTF-8 返回」,
//   实际等于把 base58 字符串原样当 UTF-8 字节返回, jsonDecode 必然抛
//   FormatException, 让本地模式订阅功能完全不可用.
//
// Bitcoin base58 alphabet:
//   123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
//   (不含 0/O/I/l 这些容易混淆的字符)
//
// 算法: 每个字符按 alphabet index 当作 58 进制位, 累加成 BigInt,
//   再转换成 bytes. 前导 '1' 当作前导 0 字节 (跟 Bitcoin 地址同款).
const String _kBase58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

List<int> base58decode(String input) {
  if (input.isEmpty) return const [];

  // 建立 char → index 反查表
  final lookup = <int, int>{};
  for (int i = 0; i < _kBase58Alphabet.length; i++) {
    lookup[_kBase58Alphabet.codeUnitAt(i)] = i;
  }

  // 数前导 '1' 的个数 (每个 '1' 对应一个前导 0 字节)
  int leadingZeros = 0;
  while (leadingZeros < input.length && input[leadingZeros] == '1') {
    leadingZeros++;
  }

  // 累加 58 进制
  BigInt num = BigInt.zero;
  for (int i = leadingZeros; i < input.length; i++) {
    final code = input.codeUnitAt(i);
    final idx = lookup[code];
    if (idx == null) {
      // 不是 base58 字符 → 抛异常让上层 catch 返 null
      throw FormatException('Invalid base58 char at $i: ${input[i]}');
    }
    num = num * BigInt.from(58) + BigInt.from(idx);
  }

  // BigInt → bytes
  final bytes = <int>[];
  while (num > BigInt.zero) {
    bytes.insert(0, (num & BigInt.from(0xff)).toInt());
    num = num >> 8;
  }

  // 前导 0 字节
  return List<int>.filled(leadingZeros, 0) + bytes;
}

/// 订阅内容解析结果
class SubscriptionContent {
  final List<SearchResource>? searchResources;

  SubscriptionContent({this.searchResources});
}

/// 用于解析订阅内容
///
/// v2.4.5: parseSubscriptionContent 改用 SearchResource.fromJson(site)
///   而不是直接调构造函数. 之前直接构造绕过 fromJson, 让 v2.4.4/v2.4.5 加的
///   api/detail/key/name/from trim 全部失效.
class SubscriptionService {
  static Future<SubscriptionContent?> parseSubscriptionContent(String content) async {
    try {
      final decoded = base58decode(content);
      final jsonString = utf8.decode(decoded);
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>?;

      List<SearchResource>? searchResources;
      final apiSite = jsonData is Map<String, dynamic> ? jsonData['api_site'] as Map<String, dynamic>? : null;
      if (apiSite != null) {
        searchResources = <SearchResource>[];
        apiSite.forEach((key, value) {
          if (value is! Map<String, dynamic>) return;
          // v2.4.5: 改用 fromJson, 复用全字段 trim.
          //   如果 site 没有 key 字段, 用 map 的 key 兜底.
          final siteWithKey = <String, dynamic>{
            'key': key,
            ...value,
          };
          searchResources!.add(SearchResource.fromJson(siteWithKey));
        });
      }

      return SubscriptionContent(searchResources: searchResources);
    } catch (e) {
      return null;
    }
  }
}
