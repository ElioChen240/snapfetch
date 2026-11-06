import '../../domain/parser.dart';
import 'douyin.dart';
import 'pan123.dart';
import 'quark.dart';
import 'uc.dart';
import 'xiaohongshu.dart';

/// 一次性注册首批 5 家（PRD §10 D1）。
/// 新增平台 = 新增一个 [LinkParser] 实现 + 在这里注册，核心零改动（§8.3）。
ParserRegistry buildDefaultRegistry() => ParserRegistry()
  ..register(QuarkParser())
  ..register(UcParser())
  ..register(Pan123Parser())
  ..register(DouyinParser())
  ..register(XiaohongshuParser());
