-- Ensure that there's a message_body row for each
-- active vector when this message send_on is set.
create or replace function notification.bodypart_for_all_vectors_and_mimetypes()
returns trigger language plpgsql as
$$
    begin
        perform fail('Need a message_bodypart row for vector '
                            || v.vector_id
                            || ' and mimetype '
                            || vmt.mimetype)
        from
            notification.vector v
                join notification.vector_mime_type vmt
                    using (vector_id)
                left join notification.message_bodypart mb
                    on (v.vector_id = mb.vector_id
                        and vmt.mimetype = mb.mimetype
                        and mb.message_id = NEW.message_id)
            where
                mb.message_id is null
            ;

        -- after trigger.
        return null;
    end;
$$;
