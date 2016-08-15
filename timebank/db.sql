--  Copyright (C) 2016 Open Lab Athens.
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
--  @license GPL-3.0+ <http://spdx.org/licenses/GPL-3.0+>
--
--
--  Changes
--
--  15-8-2016: Rowan Thorpe <rowan@rowanthorpe.com>: Original commit

--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

DROP DATABASE IF EXISTS "timebank";
--
-- Name: timebank; Type: DATABASE; Schema: -; Owner: timebank
--

CREATE DATABASE "timebank" WITH TEMPLATE = template0 ENCODING = 'UTF8' LC_COLLATE = 'el_GR.UTF-8' LC_CTYPE = 'el_GR.UTF-8';


ALTER DATABASE "timebank" OWNER TO "timebank";

\connect "timebank"

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: SCHEMA "public"; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA "public" IS 'standard public schema';


--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS "plpgsql" WITH SCHEMA "pg_catalog";


--
-- Name: EXTENSION "plpgsql"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "plpgsql" IS 'PL/pgSQL procedural language';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "public";


--
-- Name: EXTENSION "pgcrypto"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "pgcrypto" IS 'cryptographic functions';


SET search_path = "public", pg_catalog;

--
-- Name: jsonb_merge("jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "jsonb_merge"("left" "jsonb", "right" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $_$
        SELECT
          CASE WHEN jsonb_typeof($1) = 'object' AND jsonb_typeof($2) = 'object' THEN
            (
              SELECT
                json_object_agg(
                  COALESCE(o.key, n.key),
                  CASE WHEN n.key IS NOT NULL THEN
                    n.value
                  ELSE
                    o.value
                  END
                )::jsonb
              FROM jsonb_each($1) o
              FULL JOIN jsonb_each($2) n ON (n.key = o.key)
            )
          ELSE
            (
              CASE WHEN jsonb_typeof($1) = 'array' THEN
                LEFT($1::text, -1)
              ELSE
                '[' || $1::text
              END
              || ', ' ||
              CASE WHEN jsonb_typeof($2) = 'array' THEN
                RIGHT($2::text, -1)
              ELSE
                $2::text || ']'
              END
            )::jsonb
          END
    $_$;


ALTER FUNCTION "public"."jsonb_merge"("left" "jsonb", "right" "jsonb") OWNER TO "postgres";

--
-- Name: user_registered_for_service(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "user_registered_for_service"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
        BEGIN
          PERFORM 1
            FROM provided_service
            WHERE usr_id = NEW.usr_id AND service_id = NEW.service_id;
          IF FOUND THEN
            RETURN NEW;
          END IF;
          raise exception 'user-id % is not registered to provide service %', NEW.usr_id, NEW.service_id;
        END;
    $$;


ALTER FUNCTION "public"."user_registered_for_service"() OWNER TO "postgres";

--
-- Name: ||; Type: OPERATOR; Schema: public; Owner: postgres
--

CREATE OPERATOR || (
    PROCEDURE = "jsonb_merge",
    LEFTARG = "jsonb",
    RIGHTARG = "jsonb"
);


ALTER OPERATOR "public".|| ("jsonb", "jsonb") OWNER TO "postgres";

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: category; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "category" (
    "id" smallint NOT NULL,
    "categoryname" character varying(128) NOT NULL,
    "sector_id" smallint NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "category" OWNER TO "timebank";

--
-- Name: category_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "category_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "category_id_seq" OWNER TO "timebank";

--
-- Name: category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "category_id_seq" OWNED BY "category"."id";


--
-- Name: event; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "event" (
    "id" integer NOT NULL,
    "starttime" timestamp with time zone NOT NULL,
    "duration" smallint NOT NULL,
    "attendees" smallint NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "usr_id" smallint NOT NULL,
    "service_id" smallint NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attendees_names_recording" character varying(256) DEFAULT NULL::character varying
);


ALTER TABLE "event" OWNER TO "timebank";

--
-- Name: event_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "event_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "event_id_seq" OWNER TO "timebank";

--
-- Name: event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "event_id_seq" OWNED BY "event"."id";


--
-- Name: provided_service; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "provided_service" (
    "id" smallint NOT NULL,
    "service_id" smallint NOT NULL,
    "usr_id" smallint NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "provided_service" OWNER TO "timebank";

--
-- Name: provided_service_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "provided_service_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "provided_service_id_seq" OWNER TO "timebank";

--
-- Name: provided_service_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "provided_service_id_seq" OWNED BY "provided_service"."id";


--
-- Name: sector; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "sector" (
    "id" smallint NOT NULL,
    "sectorname" character varying(128) NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "sector" OWNER TO "timebank";

--
-- Name: sector_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "sector_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "sector_id_seq" OWNER TO "timebank";

--
-- Name: sector_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "sector_id_seq" OWNED BY "sector"."id";


--
-- Name: service; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "service" (
    "id" smallint NOT NULL,
    "servicename" character varying(128) NOT NULL,
    "category_id" smallint NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "service" OWNER TO "timebank";

--
-- Name: service_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "service_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "service_id_seq" OWNER TO "timebank";

--
-- Name: service_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "service_id_seq" OWNED BY "service"."id";


--
-- Name: usr; Type: TABLE; Schema: public; Owner: timebank; Tablespace: 
--

CREATE TABLE "usr" (
    "id" smallint NOT NULL,
    "username" character varying(32) NOT NULL,
    "email" character varying(254) NOT NULL,
    "phone" character varying(15) NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified" timestamp with time zone DEFAULT "now"() NOT NULL,
    "pin" "bytea",
    "allow_pinless" boolean DEFAULT false NOT NULL,
    "allow_pin" boolean DEFAULT false NOT NULL,
    CONSTRAINT "usr_email_check" CHECK ((("email")::"text" ~ '.*@.*\..*'::"text")),
    CONSTRAINT "usr_phone_check" CHECK ((("phone")::"text" ~ '^[0-9]+$'::"text"))
);


ALTER TABLE "usr" OWNER TO "timebank";

--
-- Name: usr_id_seq; Type: SEQUENCE; Schema: public; Owner: timebank
--

CREATE SEQUENCE "usr_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "usr_id_seq" OWNER TO "timebank";

--
-- Name: usr_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: timebank
--

ALTER SEQUENCE "usr_id_seq" OWNED BY "usr"."id";


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "category" ALTER COLUMN "id" SET DEFAULT "nextval"('"category_id_seq"'::"regclass");


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "event" ALTER COLUMN "id" SET DEFAULT "nextval"('"event_id_seq"'::"regclass");


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "provided_service" ALTER COLUMN "id" SET DEFAULT "nextval"('"provided_service_id_seq"'::"regclass");


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "sector" ALTER COLUMN "id" SET DEFAULT "nextval"('"sector_id_seq"'::"regclass");


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "service" ALTER COLUMN "id" SET DEFAULT "nextval"('"service_id_seq"'::"regclass");


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "usr" ALTER COLUMN "id" SET DEFAULT "nextval"('"usr_id_seq"'::"regclass");


--
-- Data for Name: category; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "category" ("id", "categoryname", "sector_id", "created", "modified", "data") FROM stdin;
\.


--
-- Name: category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"category_id_seq"', 0, true);


--
-- Data for Name: event; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "event" ("id", "starttime", "duration", "attendees", "data", "usr_id", "service_id", "created", "modified", "attendees_names_recording") FROM stdin;
\.


--
-- Name: event_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"event_id_seq"', 0, true);


--
-- Data for Name: provided_service; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "provided_service" ("id", "service_id", "usr_id", "modified", "created", "data") FROM stdin;
\.


--
-- Name: provided_service_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"provided_service_id_seq"', 0, true);


--
-- Data for Name: sector; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "sector" ("id", "sectorname", "created", "modified", "data") FROM stdin;
\.


--
-- Name: sector_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"sector_id_seq"', 0, true);


--
-- Data for Name: service; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "service" ("id", "servicename", "category_id", "modified", "created", "data") FROM stdin;
\.


--
-- Name: service_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"service_id_seq"', 0, true);


--
-- Data for Name: usr; Type: TABLE DATA; Schema: public; Owner: timebank
--

COPY "usr" ("id", "username", "email", "phone", "data", "created", "modified", "pin", "allow_pinless", "allow_pin") FROM stdin;
\.


--
-- Name: usr_id_seq; Type: SEQUENCE SET; Schema: public; Owner: timebank
--

SELECT pg_catalog.setval('"usr_id_seq"', 0, true);


--
-- Name: category_categoryname_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "category"
    ADD CONSTRAINT "category_categoryname_key" UNIQUE ("categoryname");


--
-- Name: category_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "category"
    ADD CONSTRAINT "category_pkey" PRIMARY KEY ("id");


--
-- Name: event_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "event"
    ADD CONSTRAINT "event_pkey" PRIMARY KEY ("id");


--
-- Name: provided_service_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "provided_service"
    ADD CONSTRAINT "provided_service_pkey" PRIMARY KEY ("id");


--
-- Name: sector_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "sector"
    ADD CONSTRAINT "sector_pkey" PRIMARY KEY ("id");


--
-- Name: sector_sectorname_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "sector"
    ADD CONSTRAINT "sector_sectorname_key" UNIQUE ("sectorname");


--
-- Name: service_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "service"
    ADD CONSTRAINT "service_pkey" PRIMARY KEY ("id");


--
-- Name: service_servicename_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "service"
    ADD CONSTRAINT "service_servicename_key" UNIQUE ("servicename");


--
-- Name: usr_email_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "usr"
    ADD CONSTRAINT "usr_email_key" UNIQUE ("email");


--
-- Name: usr_phone_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "usr"
    ADD CONSTRAINT "usr_phone_key" UNIQUE ("phone");


--
-- Name: usr_pkey; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "usr"
    ADD CONSTRAINT "usr_pkey" PRIMARY KEY ("id");


--
-- Name: usr_username_key; Type: CONSTRAINT; Schema: public; Owner: timebank; Tablespace: 
--

ALTER TABLE ONLY "usr"
    ADD CONSTRAINT "usr_username_key" UNIQUE ("username");


--
-- Name: category_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "category_gin" ON "category" USING "gin" ("data");


--
-- Name: event_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "event_gin" ON "event" USING "gin" ("data");


--
-- Name: provided_service_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "provided_service_gin" ON "provided_service" USING "gin" ("data");


--
-- Name: sector_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "sector_gin" ON "sector" USING "gin" ("data");


--
-- Name: service_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "service_gin" ON "service" USING "gin" ("data");


--
-- Name: usr_gin; Type: INDEX; Schema: public; Owner: timebank; Tablespace: 
--

CREATE INDEX "usr_gin" ON "usr" USING "gin" ("data");


--
-- Name: event_usr_reg_service_ins; Type: TRIGGER; Schema: public; Owner: timebank
--

CREATE TRIGGER "event_usr_reg_service_ins" BEFORE INSERT ON "event" FOR EACH ROW EXECUTE PROCEDURE "user_registered_for_service"('usr_id', 'service_id');


--
-- Name: event_usr_reg_service_upd; Type: TRIGGER; Schema: public; Owner: timebank
--

CREATE TRIGGER "event_usr_reg_service_upd" BEFORE UPDATE OF "service_id", "usr_id" ON "event" FOR EACH ROW WHEN ((("old"."usr_id" IS DISTINCT FROM "new"."usr_id") OR ("old"."service_id" IS DISTINCT FROM "new"."service_id"))) EXECUTE PROCEDURE "user_registered_for_service"('usr_id', 'service_id');


--
-- Name: category_sector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "category"
    ADD CONSTRAINT "category_sector_id_fkey" FOREIGN KEY ("sector_id") REFERENCES "sector"("id");


--
-- Name: provided_service_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "provided_service"
    ADD CONSTRAINT "provided_service_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "service"("id");


--
-- Name: provided_service_usr_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "provided_service"
    ADD CONSTRAINT "provided_service_usr_id_fkey" FOREIGN KEY ("usr_id") REFERENCES "usr"("id");


--
-- Name: service_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: timebank
--

ALTER TABLE ONLY "service"
    ADD CONSTRAINT "service_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "category"("id");


--
-- Name: public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE ALL ON SCHEMA "public" FROM PUBLIC;
REVOKE ALL ON SCHEMA "public" FROM "postgres";
GRANT ALL ON SCHEMA "public" TO "postgres";
GRANT ALL ON SCHEMA "public" TO PUBLIC;


--
-- Name: jsonb_merge("jsonb", "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "jsonb_merge"("left" "jsonb", "right" "jsonb") FROM PUBLIC;
REVOKE ALL ON FUNCTION "jsonb_merge"("left" "jsonb", "right" "jsonb") FROM "postgres";
GRANT ALL ON FUNCTION "jsonb_merge"("left" "jsonb", "right" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "jsonb_merge"("left" "jsonb", "right" "jsonb") TO PUBLIC;


--
-- Name: user_registered_for_service(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "user_registered_for_service"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "user_registered_for_service"() FROM "postgres";
GRANT ALL ON FUNCTION "user_registered_for_service"() TO "postgres";
GRANT ALL ON FUNCTION "user_registered_for_service"() TO PUBLIC;


--
-- PostgreSQL database dump complete
--

