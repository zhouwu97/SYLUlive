import 'package:flutter/material.dart';

const marketContactTypeWeChat = 'wechat';
const marketContactTypeQQ = 'qq';
const marketContactTypePhone = 'phone';
const marketContactTypeOther = 'other';

String marketContactTypeLabel(String type) {
  switch (type) {
    case marketContactTypeWeChat:
      return '微信';
    case marketContactTypeQQ:
      return 'QQ';
    case marketContactTypePhone:
      return '电话';
    default:
      return '联系方式';
  }
}

IconData marketContactTypeIcon(String type) {
  switch (type) {
    case marketContactTypeWeChat:
      return Icons.chat_bubble_outline_rounded;
    case marketContactTypeQQ:
      return Icons.alternate_email_rounded;
    case marketContactTypePhone:
      return Icons.phone_outlined;
    default:
      return Icons.contact_page_outlined;
  }
}

TextInputType marketContactKeyboardType(String type) {
  switch (type) {
    case marketContactTypeQQ:
      return TextInputType.number;
    case marketContactTypePhone:
      return TextInputType.phone;
    default:
      return TextInputType.text;
  }
}

String marketContactInputHint(String type) {
  switch (type) {
    case marketContactTypeWeChat:
      return '请输入微信号';
    case marketContactTypeQQ:
      return '请输入QQ号';
    case marketContactTypePhone:
      return '请输入手机号';
    case marketContactTypeOther:
      return '历史联系方式';
    default:
      return '请先选择类型';
  }
}

String marketContactCopiedMessage(String type) {
  switch (type) {
    case marketContactTypeWeChat:
      return '微信号已复制';
    case marketContactTypeQQ:
      return 'QQ号已复制';
    case marketContactTypePhone:
      return '电话号码已复制';
    default:
      return '联系方式已复制';
  }
}
