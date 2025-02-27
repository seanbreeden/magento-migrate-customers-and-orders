#!/bin/bash

# Fill out your Database Credentials below.

# Production Database
PROD_DB_HOST=""
PROD_DB_USER=""
PROD_DB_PASS=""
PROD_DB_NAME=""

# Staging Database
STAGE_DB_HOST=""
STAGE_DB_USER=""
STAGE_DB_PASS=""
STAGE_DB_NAME=""

DUMP_FILE="customers_orders_dump.sql"
CUSTOMER_GRID_FILE="customer_grid_flat.tsv"
CUSTOMER_GROUP_FILE="customer_group_dump.sql"

echo
echo -e "\e[\e[41m****D A N G E R****\e[49m\e[25m This will overwrite STAGING with PRODUCTION data."
echo "The purpose of this script is to migrate Customers and Orders down to staging from production,"
echo "to promote staging to production."
echo
echo "Please back up your databases first before running this script!"
echo
read -n 1 -s -r -p 'Press any key to continue or CTRL+C to abort.'
clear
echo
echo "Starting data migration from production to staging..."
echo
echo "Dumping relevant customer, order, and Signifyd tables from production..."
mysqldump -h $PROD_DB_HOST -u $PROD_DB_USER -p$PROD_DB_PASS $PROD_DB_NAME \
  --no-create-info --single-transaction --quick --lock-tables=false \
  --complete-insert --skip-triggers \
  customer_entity customer_address_entity \
  sales_order sales_order_grid sales_order_address sales_order_payment \
  sales_order_status_history sales_order_item sales_order_tax sales_order_tax_item \
  sales_shipment sales_shipment_item sales_shipment_track sales_shipment_comment sales_shipment_grid \
  sales_invoice sales_invoice_item sales_invoice_grid sales_invoice_comment \
  sales_creditmemo sales_creditmemo_item sales_creditmemo_grid sales_creditmemo_comment \
  quote quote_item quote_address quote_payment quote_id_mask \
  signifyd_case signifyd_connect_case signifyd_connect_fulfillment > $DUMP_FILE

echo
echo "Data dump completed. File saved as $DUMP_FILE"
echo

# Export customer_grid_flat with only necessary columns and fix any TIMESTAMP values
echo "Dumping customer_grid_flat without extra columns and fixing TIMESTAMP values..."
mysql -B --skip-column-names -h $PROD_DB_HOST -u $PROD_DB_USER -p$PROD_DB_PASS $PROD_DB_NAME -e "
SET SESSION sql_mode='';
SELECT entity_id, name, email, group_id, created_at, website_id, confirmation, created_in, dob, gender, taxvat,
       CASE WHEN lock_expires = '0000-00-00 00:00:00' THEN NULL ELSE lock_expires END AS lock_expires,
       ac_contact_id, ac_customer_id, ac_sync_status, shipping_full, billing_full, billing_firstname,
       billing_lastname, billing_telephone, billing_postcode, billing_country_id, billing_region,
       billing_region_id, billing_street, billing_city, billing_fax, billing_vat_id, billing_company
FROM customer_grid_flat;" > $CUSTOMER_GRID_FILE
echo
echo "Customer grid data extracted. File saved as $CUSTOMER_GRID_FILE"
echo

# Clear Existing Signifyd Data in Staging to Avoid Duplicates
echo
echo "Clearing existing Signifyd data in staging..."
echo

mysql -h $STAGE_DB_HOST -u $STAGE_DB_USER -p$STAGE_DB_PASS $STAGE_DB_NAME -e "
SET FOREIGN_KEY_CHECKS=0;
TRUNCATE TABLE signifyd_case;
TRUNCATE TABLE signifyd_connect_case;
TRUNCATE TABLE signifyd_connect_fulfillment;
SET FOREIGN_KEY_CHECKS=1;"

# Import Main Data into Staging
echo "Importing main data into staging database..."
mysql -h $STAGE_DB_HOST -u $STAGE_DB_USER -p$STAGE_DB_PASS $STAGE_DB_NAME < $DUMP_FILE

echo
echo "Importing cleaned customer grid data..."
echo
# Move the customer grid file to MySQL's secure directory and set proper permissions.
sudo mv $CUSTOMER_GRID_FILE /var/lib/mysql-files/
sudo chmod 644 /var/lib/mysql-files/$(basename $CUSTOMER_GRID_FILE)
mysql -h $STAGE_DB_HOST -u $STAGE_DB_USER -p$STAGE_DB_PASS $STAGE_DB_NAME -e "
LOAD DATA INFILE '/var/lib/mysql-files/$(basename $CUSTOMER_GRID_FILE)'
INTO TABLE customer_grid_flat
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n';"

# Dump and Import Customer Groups from Production
echo
echo "Copying customer groups..."
echo
mysqldump -h $PROD_DB_HOST -u $PROD_DB_USER -p$PROD_DB_PASS $PROD_DB_NAME \
  --no-create-info --single-transaction --quick --lock-tables=false \
  customer_group > $CUSTOMER_GROUP_FILE
mysql -h $STAGE_DB_HOST -u $STAGE_DB_USER -p$STAGE_DB_PASS $STAGE_DB_NAME < $CUSTOMER_GROUP_FILE

# Reindex and Flush Cache
echo
echo "Reindexing Magento data..."
echo
php bin/magento ind:res
php bin/magento ind:rei
echo
echo "Flushing Magento cache..."
echo
php bin/magento cache:flush

echo
echo "Migration completed successfully!"
echo
