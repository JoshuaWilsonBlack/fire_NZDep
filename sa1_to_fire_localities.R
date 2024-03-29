library(tidyverse)
library(here)

# sf is used to process geographical areas.
library(sf)

# Load the fire localities data and the statistical area 1 data.
fire_locations <- st_read(
  here('data', 'fire-and-emergency-nz-localities.shp')
)
stat_locations <- st_read(
  here('data', 'statistical-area-1-2018-generalised.shp')
)
# Both are on the same projected CRS.

# We load the NZDep2018 data at the statistical area 1 level.
sa1_se <- read_csv(here('data', 'otago730395.csv'))

# We can look at the fire data for the whole country. Here we use `suburb_4th`
# which is the primary name for any 'Suburb', 'Locality', or 'Park_Reserve'
# (see data dictionary from Fire Service locality dataset).
plot(fire_locations %>% select(suburb_4th, geometry))

# We remove any fire locality which does not have a `suburb_4th` value.
fire_locations <- fire_locations %>%
  filter(
    !is.na(suburb_4th)
  )

# For all fire localities, we collect the statistical areas which intersect.
intersections <- st_intersects(fire_locations, stat_locations)
intersections <- as_tibble_col(intersections)

# We take the unique ids for each area from the fire locality data and unnest
# the list of intersecting areas. This results in a row for each pair of
# fire service localities and statistical areas which intersect.
intersections <- intersections %>%
  mutate(
    id = fire_locations$id,
  ) %>%
  unnest(cols = value)
# We are left with 58083 intersections.

# We only know which statistical area intersects by virtue of its row number in
# the `stat_location` dataframe. We use this to join the statistical areas to
# the fire localities.

# We first add a column with row numbers to `stat_locations`
stat_locations <- stat_locations %>%
  mutate(
    value = 1,
    value = cumsum(value)
  )

intersections <- intersections %>%
  left_join(as_tibble(stat_locations), by = c('value'))

# Some intersections are _very_ small (this was found by manually inspecting the
# data for Christchurch). We will perform a weighted mean of the deprivation
# index so that each statistical area contributes values to the overall mean for
# a fire locality relative to how much of it is in the fire locality.

# To do this we define a function to collect the area of the intersection given
# two names.
collect_intersect_area <- function(fire_id, sa1_code) {
  fire_shape <- fire_locations %>%
    filter(
      id == fire_id
    )
  sa2_shape <- stat_locations %>%
    filter(
      SA12018_V1 == sa1_code
    )
  # We calculate the intersection(s), calculate their area, and sum areas to
  # cover cases in which there are multiple intersections.
  out <- st_intersection(fire_shape, sa2_shape) %>% st_area() %>% sum()
}

# We apply the function to all intersections.
# This takes a while, and is probably not efficient (perhaps the package furrr
# would help here by enabling multiple areas to be generated at once). An
# alternative faster method would be to use the NZDep data for the larger SA2
# statistical areas. These are available at:
# https://www.otago.ac.nz/wellington/departments/publichealth/research/hirp/otago020194.html#2018
intersections <- intersections %>%
  mutate(
    intersection_area = map2_dbl(
      id,
      SA12018_V1, # statistical area name from stats dataset.
      collect_intersect_area
    )
  )

# We calculate the proportion of the SA1 areas which intersect each fire
# locality. The multiplication below puts SA1 size on same scale as area
# calculations.
intersections <- intersections %>%
  mutate(
    overlap_prop = intersection_area / (AREA_SQ_KM * 1000000)
  )

# Add NZ Deprivation index data
intersections <- intersections %>%
  left_join(
    sa1_se %>%
      rename(
        SA12018_V1 = SA12018_code
      ) %>%
      mutate(
        SA12018_V1 = as.character(SA12018_V1) # Match type of intersections.
      )
  )

# Take weighted mean by proportion of overlap for SA1 with fire locality.
# Also take weighted sum of URpop and calculate what proportion of the sum
# is at decile 9 or 10.
fire_se <- intersections %>%
  group_by(id) %>%
  summarise(
    NZdep_mean = weighted.mean(
      NZDep2018_Score,
      overlap_prop,
      na.rm=TRUE
    ),
    NZdep_quant_mean = weighted.mean(
      NZDep2018,
      overlap_prop,
      na.rm=TRUE
    ),
    URPopn_weighted = sum(overlap_prop * URPopnSA1_2018),
    URPopn_weighted_high = sum(
      if_else(
        NZDep2018 %in% c(9, 10),
        URPopnSA1_2018,
        0
      ) *
      overlap_prop
    ),
    URPopn_perc_high = (URPopn_weighted_high / URPopn_weighted) *  100
  )

# Add NZDep information to fire localities data set.
fire_locations <- fire_locations %>%
  left_join(
    fire_se
  )

# Plot by deprivation index.
plot(
  fire_locations %>%
    select(NZdep_quant_mean, geometry)
)

# Have a look at numerical summary as a sanity check.
summary(fire_locations)
# NZdep_mean and NZdep_quant_mean look OK.

# Output shape data for NZDep2018 at fire locality level
st_write(fire_locations, here('processed_data', 'fire_dep2018.shp'))

# Output summary data as csv.

# We look at the names.
names(fire_locations)
# [1] "id"                   "parent_id"            "suburb_4th"           "suburb_3rd"           "suburb_2nd"          
# [6] "suburb_1st"           "type_order"           "type"                 "city_id"              "city_name"           
# [11] "has_addres"           "start_date"           "end_date"             "majorlocal"           "majorloc_1"          
# [16] "NZdep_mean"           "NZdep_quant_mean"     "URPopn_weighted"      "URPopn_weighted_high" "URPopn_perc_high"    
# [21] "geometry"   

# We select a subset for our output csv
out_sheet_data <- fire_locations %>%
  as_tibble() %>%
  select(
    c('id', 'parent_id', 'suburb_4th', 'suburb_3rd', 'suburb_2nd', 'suburb_1st',
      'city_id', 'city_name', 'majorlocal', 'majorloc_1', 'NZdep_mean',
      'NZdep_quant_mean', 'URPopn_perc_high')
  )

write_csv(out_sheet_data, here('processed_data', 'fire_dep2018.csv'))
