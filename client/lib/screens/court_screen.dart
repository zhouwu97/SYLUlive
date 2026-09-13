import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../app_bootstrap.dart';

class CourtScreen extends StatefulWidget {
  final int appealId;
  const CourtScreen({super.key, required this.appealId});
  @override State<CourtScreen> createState() => _CourtScreenState();
}
class _CourtScreenState extends State<CourtScreen> {
  Map<String,dynamic>? _appeal; bool _loading=true; bool _submitting=false; String? _error;
  @override void initState(){super.initState(); _load();}
  Future<void> _load() async { setState((){_loading=true;_error=null;}); try { final r=await getSharedDio().get('/appeals/${widget.appealId}'); final d=r.data; if(mounted)setState(()=>_appeal=d is Map ? Map<String,dynamic>.from(d['appeal'] is Map ? d['appeal'] : d) : null); } on DioException catch(e){if(mounted)setState(()=>_error=e.response?.data is Map ? e.response?.data['error']?.toString() : '申诉详情加载失败');} catch(_){if(mounted)setState(()=>_error='申诉详情加载失败');} finally{if(mounted)setState(()=>_loading=false);}}
  Future<void> _vote(String vote) async {if(_submitting)return;setState(()=>_submitting=true);try{await getSharedDio().post('/appeals/${widget.appealId}/vote',data:{'vote':vote});if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(vote=='support'?'已投支持票':'已投反对票')));await _load();}on DioException catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.response?.data is Map ? (e.response?.data['error']?.toString()??'投票失败'):'投票失败')));}finally{if(mounted)setState(()=>_submitting=false);}}
  @override Widget build(BuildContext context){final a=_appeal;return Scaffold(appBar:AppBar(title:const Text('公众法庭')),body:_loading?const Center(child:CircularProgressIndicator()):_error!=null?Center(child:FilledButton.icon(onPressed:_load,icon:const Icon(Icons.refresh),label:Text(_error!))):a==null?const Center(child:Text('申诉不存在')):_content(a));}
  Widget _content(Map<String,dynamic>a){final status=a['status']?.toString()??'pending';final voted=a['my_vote']?.toString();final can=a['can_vote']==true||(status=='pending'&&voted==null);return ListView(padding:const EdgeInsets.all(20),children:[Text('申诉 #${a['id']??widget.appealId}',style:Theme.of(context).textTheme.titleLarge),const SizedBox(height:12),Text('处理理由',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:6),Text((a['admin_reason']??'暂无处理理由').toString()),const SizedBox(height:20),Text('当前状态：${_status(status)}'),if(voted!=null)Text('你的投票：${voted=='support'?'支持申诉':'反对申诉'}'),const SizedBox(height:28),if(can)Row(children:[Expanded(child:FilledButton.icon(onPressed:_submitting?null:()=>_vote('support'),icon:const Icon(Icons.thumb_up),label:const Text('支持申诉'))),const SizedBox(width:12),Expanded(child:FilledButton.tonalIcon(onPressed:_submitting?null:()=>_vote('oppose'),icon:const Icon(Icons.thumb_down),label:const Text('反对申诉')))])else const Text('当前不可投票')]);}
  String _status(String s)=>switch(s){'pending'=>'待投票','approved'=>'申诉通过','rejected'=>'申诉驳回',_=>s};
}
