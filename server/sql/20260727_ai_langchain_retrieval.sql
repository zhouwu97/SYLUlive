BEGIN;

-- Python RAG 进程只继承三张检索表的 SELECT 权限；登录角色和密码由部署系统单独创建。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shenliyuan_rag_reader') THEN
        CREATE ROLE shenliyuan_rag_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    END IF;
END
$$;

REVOKE ALL PRIVILEGES ON ai_knowledge_documents FROM shenliyuan_rag_reader;
REVOKE ALL PRIVILEGES ON ai_knowledge_chunks FROM shenliyuan_rag_reader;
REVOKE ALL PRIVILEGES ON ai_knowledge_chunk_embeddings FROM shenliyuan_rag_reader;
REVOKE CREATE ON SCHEMA public FROM shenliyuan_rag_reader;
GRANT USAGE ON SCHEMA public TO shenliyuan_rag_reader;
GRANT SELECT ON ai_knowledge_documents TO shenliyuan_rag_reader;
GRANT SELECT ON ai_knowledge_chunks TO shenliyuan_rag_reader;
GRANT SELECT ON ai_knowledge_chunk_embeddings TO shenliyuan_rag_reader;

COMMIT;
