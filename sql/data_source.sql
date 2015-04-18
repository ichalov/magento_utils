select o.value, count(*) 
from catalog_product_entity_int as i, eav_attribute as a, eav_attribute_option_value as o 
where i.attribute_id = a.attribute_id and a.attribute_code = 'data_source' and i.value = o.option_id 
group by o.value;
