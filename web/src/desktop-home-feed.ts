import { useInfiniteQuery } from "@tanstack/react-query";
import { query, request, type Entity } from "./api";
import { useAuth } from "./auth";

type FeedPage = { page: number; session?: string; offset?: number };

export function useDesktopHomeFeed(sort: string) {
  const auth = useAuth();
  return useInfiniteQuery({
    queryKey: ["api", "desktop-home", sort, auth.user?.id],
    initialPageParam: { page: 1 } as FeedPage,
    enabled: !auth.loading && (sort !== "following" || !!auth.user),
    queryFn: ({ pageParam, signal }) => request<Entity>(query("/api/posts", {
      board: 1, limit: 20, sort, page: pageParam.page,
      capabilities: "feed_pagination_meta_v1",
      scene: pageParam.session ? "loadmore" : undefined,
      session_id: pageParam.session,
      offset: pageParam.offset,
    }), { signal }),
    getNextPageParam: (last, pages): FeedPage | undefined => last.has_more ? {
      page: pages.length + 1,
      session: ["all", "hot"].includes(sort) ? last.session_id || pages[0].session_id : undefined,
      // 服务端按扫描候选数推进；短页不能用已显示帖子数推导偏移。
      offset: last.next_offset,
    } : undefined,
    retry: false,
  });
}
