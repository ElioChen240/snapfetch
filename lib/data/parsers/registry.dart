import '../../domain/parser.dart';
import 'douyin.dart';
import 'pan123.dart';
import 'quark.dart';
import 'uc.dart';
import 'xiaohongshu.dart';

/// 注册 3 家网盘 + 2 家视频平台。
/// 新增平台 = 新增一个 [LinkParser] 实现 + 在这里注册，核心零改动（§8.3）。
ParserRegistry buildDefaultRegistry() => ParserRegistry()
  ..register(QuarkParser())
  ..register(UcParser())
  ..register(Pan123Parser())
  ..register(DouyinParser())
  ..register(XiaohongshuParser());
