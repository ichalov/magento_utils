<?php

/*  Author: Victor Ichalov <ichalov@gmail.com>
 *  The script produces a simplified version of full text index. It only supports text, varchar, int and dropdown 
 *  attributes. It doesn't support multistore configurations and configurable products.
 */

require_once 'abstract.php';

class Mage_Shell_Full_Text_Search_Indexer extends Mage_Shell_Abstract {

    public function run() {

        $resource = Mage::getSingleton('core/resource');
        $r = $resource->getConnection('core_read');
        $w = $resource->getConnection('core_write');

        $attr_tmp = $r->fetchAll("select a.* from eav_attribute as a, catalog_eav_attribute as c where a.attribute_id = c.attribute_id and c.is_searchable = 1");
        $attrs = array();
        foreach($attr_tmp as $a) {
            $attrs[$a['attribute_id']] = $a['attribute_code'];
        }
        $attr_ids = array_keys($attrs);

        $attr_opt_tmp = $r->fetchAll("select * from eav_attribute_option_value");
        $opt_vals = array();
        foreach ($attr_opt_tmp as $o) {
            $opt_vals[$o['option_id']] = $o['value'];
        }

        $prods = array();
        foreach (array('text', 'varchar') as $tab_suffix) {
            $sth = $r->query("select * from catalog_product_entity_".$tab_suffix);
            while ($row = $sth->fetch()) {
                if (in_array((int)$row['attribute_id'], $attr_ids)) {
                    $prods[$row['entity_id']][$row['attribute_id']] = $row['value'];
                }
            }
        }

        $sth = $r->query("select * from catalog_product_entity_int");
        while ($row = $sth->fetch()) {
            if (in_array((int)$row['attribute_id'], $attr_ids)) {
                $prods[$row['entity_id']][$row['attribute_id']] = $opt_vals[$row['value']]?$opt_vals[$row['value']]:$row['value'];
            }
        }

        $w->query("update index_process set status = 'working', started_at = Now() where indexer_code = 'catalogsearch_fulltext'");
        $w->query("truncate table catalogsearch_fulltext");

        $sth = $r->query("select * from catalog_product_entity");
        $cur_list = array();
        $count = 0;
        while ($p = $sth->fetch()) {
            $prod_id = $p['entity_id'];
            $text = $p['sku'];
            foreach ($attr_ids as $a) {
                if (isset($prods[$prod_id][$a])) {
                    $text .= "|".$prods[$prod_id][$a];
                }
            }
            $text = addslashes($text);
            $cur_list[] = "($prod_id,1,'$text')";
            if (++$count == 100) {
                $w->query("insert into catalogsearch_fulltext(product_id, store_id, data_index) values ".implode(",", $cur_list));
                $count = 0;
                $cur_list = array();
            }
        }
        if ($count) {
            $w->query("insert into catalogsearch_fulltext(product_id, store_id, data_index) values ".implode(",", $cur_list));
        }
        $w->query("update index_process set status = 'pending', ended_at = Now() where indexer_code = 'catalogsearch_fulltext'");
    }
}

$shell = new Mage_Shell_Full_Text_Search_Indexer();
$shell->run();


