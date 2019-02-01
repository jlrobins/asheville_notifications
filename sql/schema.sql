\set ON_ERROR_STOP 1


drop database if exists aville;
create database aville;
\c aville;

begin;

    --
    -- New sub-system, new schema to hold the moving parts
    -- (enumerations, lookup tables, as well as the
    -- expected-to-be-modified at runtime by webspace tables.
    --
    -- Sometimes desired to put the webspace-modifiable
    -- tables into a separate schema for more ease of
    -- postgresql-user-account permissioning, but we'll let
    -- that slide here for now)
    --
    create schema notification;

    -- all newly created objects will be in 'notification' by default.
    set search_path = notification, public;

    -- Sample initial set. More can be added in the future via
    -- adding values within here, plus then also a corresponding
    -- row in the subsequent 'category' table. This enumeration
    -- is itself useful at the SQL level because it will display
    -- as a string for readability, but stored as an int. No more
    -- 'magic int' knowledge and unhygenic queries referencing
    -- magic constants.

    -- Pattern of an enumerated type, plus then a table
    -- holding the metadata for that enumerated type
    -- value (plus also being a target for foreign keys)
    -- is common, and allows for the logical *deletion*
    -- of an enumerated type value when you delete it
    -- from the lookup metadata table. PostgreSQL
    -- does not support ALTER TYPE ... DROP VALUE ... .
    -- because it cannot guarantee that index rows referencing
    -- the dead value don't exist.
    create type category_type
            as enum ('CONSTRUCTION_PROJECT', 'BOND_PACKAGE');

    create table category
    (
        category_id category_type primary key,
        display_label text not null
            check (length(display_label) < 1200)

        -- Other metadata here ...
    );

    insert into category (category_id, display_label)
    values
        ('CONSTRUCTION_PROJECT', 'Construction Projects'),
        ('BOND_PACKAGE', 'Bond Packages');


    -- Things people can subscribe to, be they individual construction
    -- projects or "all construction projects" (differentiated by
    -- is_general_category_topic)
    create table topic
    (
        topic_id serial primary key,

        category_id category_type
            not null
            references category(category_id),

        created timestamptz not null default now(),

        is_general_category_topic boolean not null default false,

        -- main display headline and then description of this
        -- subscribeable, with reasonable length constraints
        -- to keep people from going nuts here. These are
        -- *not* individual message subject / bodies per se.
        subject text not null check (length(subject) < 1200),
        description text not null check (length(description) < 10000)
    );

    -- Create the general category topics ("meta-topics")
    insert into topic
        (category_id, is_general_category_topic, subject, description)
    select
        category_id, true, display_label,
        display_label || ' description (please improve)'
    from category;


    -- there can be only one (and should be exactly one) topic
    -- for each general category. Partial unique index.
    create unique index general_category_topic_idx
        on topic(category_id)
        where is_general_category_topic;

    create index topic_category on topic(category_id);

    -- one day grow SMS, or FB_MESSENGER, or whatnot ...
    create type vector_type as enum ('EMAIL');

    create table vector
    (
        vector_id vector_type primary key,

        vector_address_label text not null unique,

        -- for verifying, see subscriber_vector.adddress
        -- checking trigger.
        address_like_pattern text not null
    );

    insert into vector values (
        'EMAIL',
        'Email Address',
        '%@%'   -- could well be improved upon here for email
                -- validation, namely through storing reference
                -- to a validation *function*, not just a brittle
                -- and coarse like pattern. But, uh, I've got to
                -- stop adding featurettes here at some point.
    );

    -- A message to publish on a topic.
    create table message
    (
        message_id serial primary key,

        topic_id int not null
            references topic,

        created timestamptz not null default now(),

        send_on timestamptz
            check (send_on >= created),

        title text not null
            check (length(title) < 100)

        -- body of the message smeared across
        -- one or more message_bodypart rows, table coming up.
    );

    create index message_topic_idx
        on message(topic_id);

    create index message_send_on_idx
        on message(send_on) where send_on is not null;

    -- may well end up web displaying old messages and
    -- paginating based on created, so ...
    create index message_created
        on message(created);

    -- Additional meta-data for message_bodypart table.
    -- Our emails will be mime-multipart with both plain and html
    -- sub-parts.
    create type supported_mime_type
        as enum ('text/plain', 'text/html');

    -- which vector + mimetype combos are required?
    create table vector_mime_type
    (
        vector_id vector_type not null,
        mimetype supported_mime_type not null,

        -- possibly also grow nullable max_bodypart_lenth
        -- here.

        primary key (vector_id, mimetype)
    );

    -- Email vector requires both our current mimetypes.
    --
    insert into vector_mime_type
        values
            ('EMAIL', 'text/plain'),
            ('EMAIL', 'text/html')
    ;
    -- When SMS comes about, would wire it up
    -- to only support text/plain, or perhaps
    -- make up a pseudo-mimetype for a Real Short
    -- SMS.


    -- Store the body part(s) of a message. One per
    -- each possible (mimetype, vector_id) combination.
    create table message_bodypart
    (
        message_id int not null
            references message,

        vector_id vector_type not null
            references vector,

        mimetype supported_mime_type not null,

        body text not null,

        primary key (message_id, vector_id, mimetype),

        foreign key (vector_id, mimetype)
            references vector_mime_type
                    (vector_id, mimetype)
    );

    -- Yay, finally -- our citizens who want notifications!
    create table subscriber
    (
        subscriber_id serial primary key,
        fullname text not null
    );

    -- Subscriber's address for use with this vector.
    create table subscriber_vector
    (
        subscriber_id int not null
            references subscriber
            on delete cascade,

        vector_id vector_type not null
            references vector,

        address text not null,

        primary key (subscriber_id, vector_id)
    );

    -- And what topic + vector combinations they're
    -- interested in!
    create table subscription
    (
        subscriber_id int not null,

        vector_id vector_type not null,

        topic_id int not null
            references topic,

        primary key (subscriber_id, vector_id, topic_id),
        foreign key (subscriber_id, vector_id)
            references subscriber_vector(subscriber_id, vector_id)
            on delete cascade
    );

    -- And finally a table to track message -> subscription
    -- and that pairing's transmission status. It is expected
    -- that once a message's send_on passes, then we materialize
    -- records here to represent 'queueing up' these messages
    -- for transmission, and as they're queued up successfully
    -- we mark they have been 'sent' here.

    -- Stored function (but not trigger)
    -- populate_message_transmission_queue()
    -- will populate. It is expected that
    -- populate_message_transmission_queue()
    -- will be called by a cronjob periodically.

    -- This is populated 'late' in order to support the creation
    -- of messages to be sent 'in the future' instead of
    -- immedately. This feature has been found very popular
    -- in James' experience. If this is not needed, then
    -- the schema can be simplified a good deal.

    create table message_transmission_queue
    (

        message_id int not null
            references message,

        -- sadly de-normal/redundant given message_id, but needed
        -- for the multipart foreign key to subscription.
        topic_id int not null,

        subscriber_id int not null,

        vector_id vector_type not null,

        enqueued timestamptz
            not null default now(),

        transmitted timestamptz
            check (transmitted >= enqueued),

        primary key (message_id, subscriber_id, vector_id),

        foreign key (subscriber_id, vector_id)
            references subscriber_vector (subscriber_id, vector_id)
            on delete cascade,

        foreign key (subscriber_id, vector_id, topic_id)
            references subscription (subscriber_id, vector_id, topic_id)
            on delete cascade
    );

    -- Note that the above, with the pair of 'on delete cascade'
    -- foreign keys, will preclude this table from providing
    -- accurate "how many messages did we send last month" type
    -- reporting queries, since changes to subscriptions will
    -- cause the transmission history to change.

    -- If that sort of reporting is desired, we should probably
    -- snapshot these rows into a longer-term side-table
    -- w/o the foreign keys (and therefore also the delete clauses)
    -- when the row edges to transmitted. That could be done
    -- sanely in a trigger watching for transmitted to go non-null.



    -- index to assist with the 'on delete cascades'. The other
    -- columns in these multikey FKs add little entropy and
    -- cardinality relative to subscriber_id, so just it will
    -- suffice.
    create index message_tx_subscriber_idx
        on message_transmission_queue(subscriber_id);

    /* Now install stored procedures and triggers */

    -- Function to populate message_transmission_queue given all
    -- current subscriptions and all messages ready to be sent.
    \i notification/functions/populate_message_transmission_queue.sql

    -- general 'raise exception' fxn and trigger function ...
    \i public/functions/fail.sql

    /* Ensure subscriber_vector.address values
        conform to vector.address_like_pattern */
    \i notification/functions/check_vector_address_sanity.sql
    create trigger check_vector_address_sanity
        after insert or update
        on subscriber_vector
        for each row
        execute function notification.check_vector_address_sanity();


   -- prevent updates on subscription, only want inserts / deletes
    create trigger no_updates
        after update
        on subscription
        for each row execute function
            public.fail_trigger('Do not update, insert or delete instead');

    -- Ensure that subscriptions
    -- for the meta-topics (those with is_general_category_topic lit)
    -- physically 'imply' all subtopics of that category, both
    -- initially (materialize_meta_subscription)
    -- and in the future (materialize_subtopic_subscriptions).

    -- Yes, going with "if you first check some subtopics, then
    -- the pseudo-topic, then uncheck the pseudo-topic, you lose
    -- your original subtopics". Something has to give.
    -- (dematerialize_meta_subscription_implications)

    \i notification/functions/materialize_meta_subscription_trigger.sql
    create trigger materialize_meta_subscription
        after insert or update
        on subscription
        for each row
        execute function notification.materialize_meta_subscription_trigger();

    \i notification/functions/new_subtopic_materialize_meta_subscriptions_trigger.sql
    create trigger materialize_subtopic_subscriptions
        after insert
        on topic
        for each row
        when (not NEW.is_general_category_topic)
        execute function notification.new_subtopic_materialize_meta_subscriptions_trigger();

    \i notification/functions/delete_meta_subscription_cascades_trigger.sql
    create trigger dematerialize_meta_subscription_implications
        after delete
        on subscription
        for each row
        execute function notification.delete_meta_subscription_cascades_trigger();

    -- Topics should never change category_id, otherwise the above
    -- triggers are incomplete.
    create trigger category_permanence
        after update
        on topic
        for each row
        when (NEW.category_id != OLD.category_id)
        execute function fail_trigger('Do not change category_id; delete + insert new instead.')
    ;

    -- Topics should never change their is_general_category_topic value.
    -- Likewise, otherwise the above triggers are incomplete.
    create trigger general_category_permanence
        after update
        on topic
        for each row
        when (NEW.is_general_category_topic != OLD.is_general_category_topic)
        execute function fail_trigger('Do not change is_general_category_topic; delete + insert new instead.')
    ;


    /* Guarantee that by TX end each category has a single
        is_general_category_topic topic row.

        Bi-direction constraints
        guarding inserts to category and deletes on topic making use
        of the same general trigger function which wholly ignores NEW or OLD.

        Topic and category creation / deletion are deemed rarely ocurring.
    */

    \i notification/functions/ensure_category_covered_by_general_topic.sql
    create constraint trigger ensure_category_covered_by_general_topic
        after insert
        on category
        deferrable initially deferred -- run at TX end pls.
        for each row
        execute function notification.ensure_category_covered_by_general_topic();

    create constraint trigger ensure_category_covered_by_general_topic
        after delete
        on topic
        deferrable initially deferred -- run at TX end pls.
        for each row
        execute function notification.ensure_category_covered_by_general_topic();


    -- Ensure that when a message is blessed for sending,
    -- that it better have a message_body for every active
    -- vector.
    \i notification/functions/bodypart_for_all_vectors_and_mimetypes.sql
    create constraint trigger ensure_message_body_for_all_vectors
        after update or insert
        on message
        deferrable initially deferred -- run at TX end pls.
        for each row
        when (NEW.send_on is not null)
        execute function notification.bodypart_for_all_vectors_and_mimetypes()
    ;

    -- Subscribers must be covered by subscriber_vector rows
    \i notification/functions/ensure_subscriber_vector_coverage.sql
    create constraint trigger ensure_subscriber_vector_coverage
        after insert
        on subscriber
        deferrable initially deferred -- run at TX end pls.
        for each row
        execute function notification.ensure_subscriber_vector_coverage()
    ;

commit;

-- For quick sanity debugging.
\i sql_test_suite.sql;

