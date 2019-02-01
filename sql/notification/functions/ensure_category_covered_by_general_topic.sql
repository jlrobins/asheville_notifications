-- Ensure that each category is covered by a distinguished topic.

create or replace function notification.ensure_category_covered_by_general_topic()
returns trigger
language plpgsql as
$$
	begin
		perform fail('Category ' || c.category_id || ' not covered by a general category topic!')
		from
			notification.category c
				left join notification.topic t
					on (c.category_id = t.category_id and t.is_general_category_topic)
			where
				t.category_id is null;

		-- after trigger
		return null;
	end;
$$;
