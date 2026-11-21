[out:json][timeout:180];
area["ISO3166-1"="SG"][admin_level=2]->.sg;
(
  nwr["name"]["leisure"~"^(park|nature_reserve|marina|stadium)$"](area.sg);
  nwr["name"]["natural"="beach"](area.sg);
  nwr["name"]["tourism"~"^(museum|aquarium|zoo|theme_park|attraction|viewpoint)$"](area.sg);
  nwr["name"]["amenity"~"^(library|cafe|food_court|place_of_worship)$"](area.sg);
  nwr["name"]["railway"="station"]["station"~"subway|light_rail"](area.sg);
  nwr["name"]["shop"="mall"](area.sg);
);
out center tags;
