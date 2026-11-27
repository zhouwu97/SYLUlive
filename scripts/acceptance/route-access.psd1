@{
    Super = @{
        '^\w+ /api/super(?:/|$)' = 'server/cmd/main.go:2353'
        '^POST /api/admin/promote$' = 'server/cmd/main.go:2251'
        '^\w+ /api/admin/competition-awards/verifications(?:/|$)' = 'server/cmd/main.go:2251'
        '^POST /api/admin/lottery/:id/draw$' = 'server/cmd/main.go:2774'
        '^POST /api/admin/class-period-profiles/:id/publish$' = 'server/cmd/main.go:2808 (handler)'
        '^POST /api/admin/ai/knowledge/(release|rollback|:id/(publish|revoke|supersede))$' = 'server/cmd/main.go:2814 (handler)'
    }
    Admin = @{
        '^\w+ /api/(api/)?admin(?:/|$)' = 'server/cmd/main.go:2156,2482'
        '^(GET /api/reports|PUT /api/reports/:id/handle)$' = 'server/cmd/main.go:2099'
        '^PUT /api/tutorial/:key$' = 'server/cmd/main.go:2443'
        '^(GET /api/(announcements|notices)/admin/list|POST /api/(announcements|notices)|(?:PUT|DELETE) /api/(announcements|notices)/:id)$' = 'server/cmd/main.go:2083,server/cmd/announcement_routes.go:37'
        '^((GET /api/teachers/(pending|logs|admin/:id/votes))|(PUT /api/teachers/:id/verify)|(DELETE /api/teachers/:id/reject)|(POST /api/teachers/(:id/merge-into|admin/:id/vote-remove)))$' = 'server/cmd/main.go:2457,2523'
        '^(GET /api/majors/pending|PUT /api/majors/:id/verify|DELETE /api/majors/:id(/reject)?)$' = 'server/cmd/main.go:2597'
        '^(GET /api/canteens/(pending|admin-list|:id/(display-tags|admin-dishes)|dish-photos/:photoId)|POST /api/canteens/(:id/(approve|offline|online)|dish-photos/:photoId/(archive|cover)|dishes/:dishId/merge)|DELETE /api/canteens/:id(/pending)?|PUT /api/canteens/:id/(image|display-tags)|PATCH /api/canteens/(:id|dishes/:dishId))$' = 'server/cmd/main.go:2663'
        '^(POST /api/violations|PUT /api/violations/:id/appeal)$' = 'server/cmd/main.go:2744'
    }
}
