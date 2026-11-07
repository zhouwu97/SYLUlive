import { useInfiniteQuery } from "@tanstack/react-query";
import { query, request, type Entity } from "./api";
import { useAuth } from "./auth";

type FeedPage = { page: number; session?: string; offset?: number; cursor?: string };

export function useDesktopHomeFeed(sort: string) {
  const auth = useAuth();
  return useInfiniteQuery({
    queryKey: ["api", "desktop-home", sort, auth.user?.id],
    initialPageParam: { page: 1 } as FeedPage,
    enabled: !auth.loading && (sort !== "following" || !!auth.user),
    queryFn: ({ pageParam, signal }) => request<Entity>(query("/api/posts", {
      board: 1, limit: 20, sort, page: pageParam.page,
      capabilities: "feed_pagination_meta_v1,poll_v1",
      // 与 App 一致走新版首页信息流（综合、最新），投票作为帖子混排
      feed_version: ["all", "time"].includes(sort) ? 3 : undefined,
      cursor: pageParam.cursor,
      scene: pageParam.session ? "loadmore" : undefined,
      session_id: pageParam.session,
      offset: pageParam.offset,
    }), { signal }),
    getNextPageParam: (last, pages): FeedPage | undefined => last.has_more ? {
      page: pages.length + 1,
      session: ["all", "hot"].includes(sort) ? last.session_id || pages[0].session_id : undefined,
      // 服务端按扫描候选数推进；短页不能用已显示帖子数推导偏移。
      offset: last.next_offset,
      cursor: sort === "time" ? last.next_cursor_token : undefined,
    } : undefined,
    retry: false,
  });
}
