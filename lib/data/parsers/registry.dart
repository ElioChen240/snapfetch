import '../../domain/parser.dart';
import 'pan123.dart';
import 'quark.dart';
import 'uc.dart';

/// 注册三家网盘（夸克 / UC / 123 云盘）。
/// 新增平台 = 新增一个 [LinkParser] 实现 + 在这里注册，核心零改动（§8.3）。
ParserRegistry buildDefaultRegistry() => ParserRegistry()
  ..register(QuarkParser())
  ..register(UcParser())
  ..register(Pan123Parser());
