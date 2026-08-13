import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../config/api_constants.dart';
import '../models/canteen.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../utils/responsive_util.dart';
import '../widgets/canteen/canteen_ranking_card.dart';
import '../widgets/image_upload_widget.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'canteen_detail_screen.dart';

/// 校园食堂页：食堂排行 + 搜索 + 提交食堂。
class CanteenScreen extends StatefulWidget {
  const CanteenScreen({super.key});

  @override
  State<CanteenScreen> createState() => _CanteenScreenState();
}

class _CanteenScreenState extends State<CanteenScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<CanteenProvider>().loadCanteens();
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _currentQuery {
    final query = _searchCtrl.text.trim();
    return query.isEmpty ? null : query;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '校园食堂',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: RankingTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: RankingTokens.titleColor(isDark),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '今天吃什么，先看看同学们的真实评价',
              style: TextStyle(
                fontSize: 12,
                color: RankingTokens.subColor(isDark),
              ),
            ),
          ),
          _buildSearchBar(isDark),
          _buildSectionHeader(isDark),
          Expanded(child: _buildCanteenList(isDark)),
        ],
      ),
      floatingActionButton: _buildFAB(isDark, accent),
    );
  }

  // ── Section header ────────────────────────────────────────────────

  Widget _buildSectionHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '食堂排行',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: RankingTokens.titleColor(isDark),
          ),
        ),
      ),
    );
  }

  // ── Search bar ────────────────────────────────────────────────────

  Widget _buildSearchBar(bool isDark) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Container(
          height: RankingTokens.searchHeight,
          decoration: BoxDecoration(
            color: RankingTokens.cardBg(isDark),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: RankingTokens.borderColor(isDark)),
          ),
          child: TextField(
            controller: _searchCtrl,
            style: TextStyle(
              fontSize: 14,
              color: RankingTokens.titleColor(isDark),
            ),
            decoration: InputDecoration(
              hintText: '搜索食堂 / 店铺...',
              hintStyle: TextStyle(
                fontSize: 14,
                color: RankingTokens.mutedColor(isDark),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 20,
                color: RankingTokens.subColor(isDark),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (value) => setState(() {}),
          ),
        ),
      );

  // ── Canteen list ──────────────────────────────────────────────────

  Widget _buildCanteenList(bool isDark) {
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.role == 'admin' || user?.role == 'super_admin';

    return Consumer<CanteenProvider>(
      builder: (_, provider, __) {
        final query = _currentQuery?.toLowerCase();
        final canteens = query == null
            ? provider.canteens
            : provider.canteens
                .where((m) => m.name.toLowerCase().contains(query))
                .toList();

        if (provider.isLoading && provider.canteens.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!provider.isLoading &&
            provider.canteens.isEmpty &&
            provider.errorMessage != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  provider.errorMessage!,
                  style: TextStyle(color: RankingTokens.subColor(isDark)),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () =>
                      context.read<CanteenProvider>().loadCanteens(),
                  child: const Text('重新加载'),
                ),
              ],
            ),
          );
        }

        if (canteens.isEmpty && !provider.isLoading) {
          return Center(
            child: Text(
              '暂无食堂',
              style: TextStyle(color: RankingTokens.subColor(isDark)),
            ),
          );
        }

        Widget buildCard(int index) {
          final canteen = canteens[index];
          return CanteenRankingCard(
            rank: index + 1,
            canteenId: canteen.id,
            name: canteen.name,
            imageUrl: canteen.image.isNotEmpty
                ? ApiConstants.fullUrl(canteen.image)
                : '',
            averageStar: canteen.averageStar,
            ratingCount: canteen.ratingCount,
            dishCount: canteen.dishCount,
            dishPhotoCount: canteen.dishPhotoCount,
            onLongPress: isAdmin
                ? () => _confirmDelete(canteen)
                : null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CanteenDetailScreen(
                  canteenId: canteen.id,
                  canteenName: canteen.name,
                ),
              ),
            ).then((_) {
              if (!mounted) return;
              context.read<CanteenProvider>().loadCanteens();
            }),
          );
        }

        Widget listContent = RefreshIndicator(
          onRefresh: () => context.read<CanteenProvider>().loadCanteens(),
          child: ResponsiveUtil.isDesktop(context)
              ? MasonryGridView.count(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
                  crossAxisCount:
                      MediaQuery.of(context).size.width > 900 ? 3 : 2,
                  mainAxisSpacing: RankingTokens.cardGap,
                  crossAxisSpacing: RankingTokens.cardGap,
                  itemCount: canteens.length,
                  itemBuilder: (_, index) => buildCard(index),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                  itemCount: canteens.length,
                  itemBuilder: (_, index) => buildCard(index),
                ),
        );

        if (provider.isLoading && provider.canteens.isNotEmpty) {
          return Stack(
            children: [
              listContent,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
            ],
          );
        }

        return listContent;
      },
    );
  }

  Future<void> _confirmDelete(Canteen canteen) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除店铺'),
        content: Text('确定要删除食堂/店铺 "${canteen.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success =
        await context.read<CanteenProvider>().deleteCanteen(canteen.id);
    if (success && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('删除成功')));
      context.read<CanteenProvider>().loadCanteens();
    }
  }

  // ── FAB ───────────────────────────────────────────────────────────

  Widget _buildFAB(bool isDark, Color accent) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe > 0 ? bottomSafe : 0),
      child: FloatingActionButton.extended(
        heroTag: 'canteen_screen_fab',
        onPressed: () => _showAddCanteenSheet(accent, isDark),
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
        label: const Text(
          '提交食堂',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  // ── Add canteen sheet ─────────────────────────────────────────────

  Future<void> _showAddCanteenSheet(Color accent, bool isDark) async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后提交食堂')));
      return;
    }

    final nameCtrl = TextEditingController();
    List<String> uploadedImageUrls = [];
    var submitting = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                decoration: BoxDecoration(
                  color: RankingTokens.cardBg(isDark),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: RankingTokens.borderColor(isDark),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: RankingTokens.canteenAccentSoft(isDark),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.storefront_rounded,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '提交食堂',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: RankingTokens.titleColor(isDark),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '填写名称并上传一张店铺图片',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: RankingTokens.subColor(isDark),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: nameCtrl,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: '请输入食堂 / 店铺名',
                          hintStyle: TextStyle(
                            color: RankingTokens.subColor(isDark),
                          ),
                          prefixIcon: const Icon(Icons.restaurant_rounded),
                          filled: true,
                          fillColor: RankingTokens.pageBg(isDark),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: RankingTokens.borderColor(isDark)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                                color: RankingTokens.borderColor(isDark)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: accent, width: 1.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ImageUploadWidget(
                        maxImages: 1,
                        largeCard: true,
                        emptyTitle: '添加图片',
                        emptySubtitle: '建议上传店铺门面或招牌图',
                        onImagesUploaded: (images) {
                          uploadedImageUrls =
                              images.map((e) => e.url).toList();
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: submitting
                                  ? null
                                  : () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                side: BorderSide(
                                  color: RankingTokens.borderColor(isDark),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: submitting
                                  ? null
                                  : () async {
                                      final name = nameCtrl.text.trim();
                                      if (name.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请输入食堂 / 店铺名'),
                                          ),
                                        );
                                        return;
                                      }
                                      if (uploadedImageUrls.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请上传一张食堂封面图片'),
                                          ),
                                        );
                                        return;
                                      }

                                      setModalState(() => submitting = true);
                                      final success = await context
                                          .read<CanteenProvider>()
                                          .addCanteen(
                                            name,
                                            uploadedImageUrls.first,
                                          );
                                      if (!mounted || !sheetContext.mounted) {
                                        return;
                                      }
                                      setModalState(() => submitting = false);
                                      if (success) {
                                        Navigator.pop(sheetContext);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                '已提交审核，审核通过后会显示在食堂页'),
                                          ),
                                        );
                                        await context
                                            .read<CanteenProvider>()
                                            .loadCanteens();
                                      } else {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('提交失败，请稍后重试'),
                                          ),
                                        );
                                      }
                                    },
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: submitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('提交'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameCtrl.dispose();
  }
}
